// A HAND'S POSE AND A HAND'S IMPULSE -- the two gestures that are not shapes.
//
// RSG_Matcher recognises a SHAPE: a path drawn in the air, normalised to 32
// body-relative points and compared by dynamic time warping. That is the right
// machinery for a circle, a downstroke or a figure drawn deliberately, and it
// is the wrong machinery for the two things most VR powers actually want:
//
//   A POSE      a state the hand is in right now and may hold for seconds.
//               An open palm. A fist. A finger pointing. It has no path, so
//               there is nothing to normalise and nothing to warp.
//
//   AN IMPULSE  a single fast movement along the hand's own axis, over in
//               about 150 ms. A thrust, a jab, a chop. It HAS a path, but the
//               path is a straight line and the whole of the information is in
//               its speed and direction -- a matcher asked to tell a hard
//               thrust from a gentle one by shape cannot, because they are the
//               same shape.
//
// So this is a third detector beside the matcher, not a template in it. It
// lives here rather than in whichever mod wanted it first for the reason the
// capture ring lives here: anything wanting to know what a hand is doing should
// be able to ask without loading a recogniser it has no use for, and the
// alternative is every mod growing its own copy of the reads below.
//
// WHAT IS ACTUALLY WORTH CENTRALISING, and the reason this file earns its place
// rather than being three lines a caller could write itself:
//
//   MAP SPACE IS NOT ISOTROPIC. Level.HandVelAtPoint reports map units per
//   SECOND, and the vertical axis is stretched by level.pixelstretch. Dotting a
//   velocity with a hand's forward axis in that space and comparing the answer
//   to a threshold gives a DIFFERENT real thrust depending which way the hand
//   went -- a shove upward needs a different number from a shove forward, and
//   no single number can be right for both. Converting both to metric space
//   first is four lines, it is not obvious that it is needed, and the symptom
//   when it is missing is "the gesture works except when I aim up", which is
//   not a bug report anybody solves quickly. It is done once, here.
//
//   A STALE PEAK IS AN EARLIER MOVEMENT. RS_HAND_PEAK is the fastest sample in
//   a 250 ms ring, so a hand that thrust once and stopped keeps reporting that
//   fast instant for a quarter of a second afterwards. Level.HandPeakAgeMs is
//   what answers it and every caller has to remember to ask.
//
// NO MODE GATE, DELIBERATELY. The matcher's entry pose -- the off hand raised
// above the head -- exists so that the DRAWING hand never touches an input
// another mod could be reading. A pose or an impulse is not drawn, costs
// nothing to watch, and asking the other hand to be in the air would make
// casting impossible for a player holding something in it, which is the exact
// case these are wanted for. They are queries, not a mode.
//
// NOTHING HERE WRITES ANY ENGINE STATE and nothing here is a decision. It
// reports what the hand is doing; what that MEANS is the caller's.
//
// ---------------------------------------------------------------------------
// LOCAL READS, AND WHAT THAT MEANS FOR NETPLAY.
//
// Every field below is this machine's own XR runtime and is never sent -- the
// engine's own note on the subject (actor.zs, above Deflect): "HandPos and
// HandVelAtPoint are LOCAL and are never sent, so a glove must not claim it --
// decide locally and travel the result as a command." These queries are the
// deciding-locally half. A caller that turns one into damage must travel the
// result as a network event and apply it for that event's player; a caller that
// acts on one directly in the playsim has written a desync.
//
// Fire() below is the convenience for exactly that: it sends the SAME shape of
// event the matcher sends, so a consumer wires an impulse up the way it already
// wires a shape.
// ---------------------------------------------------------------------------
//
// TWO TRAPS THIS FILE IS SHAPED AROUND, both documented in rsg_capture.zs and
// both still true here:
//   ZSCRIPT IDENTIFIERS ARE CASE-INSENSITIVE, so a field and a method cannot
//   share a name even in different case. The cached settings below are named
//   cvThrust/cvPeakAge rather than thrust/peakAge for that reason.
//   `out Vector3` CRASHES THE JIT at class load. Vectors are returned by value.

class RSG_Signals : EventHandler
{
	// Hand numbers, the same way round as Level.HandVelAtPoint and the capture
	// ring take them, so nothing in this family has to convert.
	const HAND_MAIN = 0;
	const HAND_OFF  = 1;

	// HOW MANY TICS A POSE HAS TO HAVE BEEN HELD to count as held. Per hand.
	private int openFor[2];
	private int stillFor[2];
	// The last tic an impulse was reported for this hand, so one human thrust
	// -- which spans several tics and passes the test on every one of them --
	// is announced once.
	private int lastImpulse[2];

	private CVar cvEnabled;
	private CVar cvDebug;
	private CVar cvThrust;
	private CVar cvPeakAge;
	private CVar cvRepeat;
	private CVar cvStill;

	static RSG_Signals Get()
	{
		return RSG_Signals(EventHandler.Find("RSG_Signals"));
	}

	private double FloatOf(CVar c, double fallback)
	{
		return c ? c.GetFloat() : fallback;
	}
	private bool BoolOf(CVar c, bool fallback)
	{
		return c ? c.GetBool() : fallback;
	}

	override void OnRegister()
	{
		cvEnabled = CVar.FindCVar("rsg_signals");
		cvDebug   = CVar.FindCVar("rsg_debug");
		cvThrust  = CVar.FindCVar("rsg_thrust_mps");
		cvPeakAge = CVar.FindCVar("rsg_thrust_age");
		cvRepeat  = CVar.FindCVar("rsg_thrust_repeat");
		cvStill   = CVar.FindCVar("rsg_still_mps");
	}

	// ---- POSES ------------------------------------------------------------
	//
	// AN OPEN PALM, and it is three separate controls because there are three
	// separate ways of not having one:
	//
	//   FingerTouch*  capacitive contact, bit 0 a thumb resting on a surface,
	//                 bit 1 an index resting on the trigger. CONTACT, not
	//                 press -- an index resting on a trigger is gun handling,
	//                 and a hand in that pose is not an open palm however
	//                 little it is squeezing. This engine has two touch bits
	//                 and no finger curl, so this is as close to "open" as the
	//                 hardware can report.
	//   GripValue*    the raw squeeze, 0..1, before the runtime's threshold.
	//   TriggerValue* the trigger's travel, 0..1.
	//
	// STATIC AND POSE-ONLY, so a caller with no interest in this handler's
	// settings can ask without finding it first.
	static bool OpenPalm(Actor pawn, int hand)
	{
		if (!pawn) return false;
		int    touch = (hand == HAND_MAIN) ? pawn.FingerTouchMain  : pawn.FingerTouchOff;
		double grip  = (hand == HAND_MAIN) ? pawn.GripValueMain    : pawn.GripValueOff;
		double trig  = (hand == HAND_MAIN) ? pawn.TriggerValueMain : pawn.TriggerValueOff;
		return touch == 0 && grip < 0.2 && trig < 0.1;
	}

	// A FIST: the complement, and not merely "not an open palm" -- a hand
	// resting on a thumb rest with the grip loose is neither.
	static bool Fist(Actor pawn, int hand)
	{
		if (!pawn) return false;
		double grip = (hand == HAND_MAIN) ? pawn.GripValueMain : pawn.GripValueOff;
		return grip > 0.6;
	}

	// HOW LONG THAT POSE HAS BEEN HELD, in tics, 0 when it is not. This is the
	// one pose question that needs state, which is why it is on the handler and
	// not static: a "raise an open palm and hold it still" power cannot be
	// answered from one tic's worth of fields.
	int OpenHeld(int hand) const
	{
		return (hand == HAND_MAIN || hand == HAND_OFF) ? openFor[hand] : 0;
	}
	// ...AND HOW LONG IT HAS BEEN STILL, which is a different question: a palm
	// held open while the arm swings is open and is not still.
	int StillHeld(int hand) const
	{
		return (hand == HAND_MAIN || hand == HAND_OFF) ? stillFor[hand] : 0;
	}

	// ---- IMPULSES ---------------------------------------------------------
	//
	// HOW FAST THIS HAND IS MOVING ALONG ITS OWN FORWARD AXIS, IN METRES A
	// SECOND. Positive is a thrust away from the player; negative is a pull
	// back toward him, which is a usable signal in its own right.
	//
	// THE CONVERSION IS THE POINT OF THIS FUNCTION. Both the velocity and the
	// axis are moved into metric space -- the vertical scaled by
	// level.pixelstretch, everything divided by vr_vunits_per_meter -- and the
	// axis is re-normalised THERE, in the space the dot product happens in.
	// Normalising in map space and then dotting in metric space is a subtler
	// version of the same error and gives an axis that is not unit.
	static double ThrustAlongHand(Actor pawn, int hand)
	{
		if (!pawn) return 0.0;
		Vector3 vel = level.HandVelAtPoint(hand, (0, 0, 0), RS_HAND_PEAK);
		Vector3 axis = HandForward(pawn, hand);

		double stretch = level.pixelstretch;
		double upm = 32.0;
		let c = CVar.GetCVar("vr_vunits_per_meter", null);
		if (c) upm = max(c.GetFloat(), 0.0001);

		Vector3 mvel  = (vel.x, vel.y, vel.z * stretch) / upm;
		Vector3 maxis = (axis.x, axis.y, axis.z * stretch);
		if (maxis.Length() < 0.0001) return 0.0;
		return mvel dot maxis.Unit();
	}

	// THE SAME BASIS EVERY HAND-AIMED THING IN THIS FAMILY USES. The +90 on yaw
	// and the negated pitch are not fudge factors: the engine stores
	// AttackAngle as (viewYaw - 90) and AttackPitch as (-viewPitch)
	// (hw_vrmodes.cpp:1421 and :1445). A cone that tests one convention while
	// the thing it is aiming tests another reads in the headset as the aim
	// being randomly off, and that has cost this project days.
	static Vector3 HandForward(Actor pawn, int hand)
	{
		if (!pawn) return (0, 0, 0);
		double yaw = ((hand == HAND_MAIN) ? pawn.AttackAngle : pawn.OffhandAngle) + 90.0;
		double pit = -((hand == HAND_MAIN) ? pawn.AttackPitch : pawn.OffhandPitch);
		return (cos(yaw) * cos(pit), sin(yaw) * cos(pit), sin(pit));
	}

	// IS THAT A THRUST. `needMps` and `maxAgeMs` are the caller's, because
	// resting hands and a real jab are separated by a number this mod has no
	// business picking for somebody else's power -- the matcher's tolerance
	// cvar exists for the same reason. 0 for maxAgeMs does not check the age.
	static bool Thrust(Actor pawn, int hand, double needMps, double maxAgeMs)
	{
		if (!pawn || needMps <= 0) return false;
		if (maxAgeMs > 0 && level.HandPeakAgeMs(hand) > maxAgeMs) return false;
		return ThrustAlongHand(pawn, hand) >= needMps;
	}

	// ---- WATCHING, AND ANNOUNCING -----------------------------------------
	//
	// The queries above are the whole service and need none of this. What this
	// tick adds is the two things a query cannot do: counting how long a pose
	// has been held, and firing an event so a consumer can wire an impulse up
	// the same way it wires a matched shape.
	override void WorldTick()
	{
		// OFF BY DEFAULT and separately from the matcher. The queries above
		// still work when this is off -- they are static and read nothing but
		// engine fields -- so switching this off costs a caller the held-pose
		// counters and the event, not the service.
		if (!BoolOf(cvEnabled, false)) return;
		if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS) return;
		if (!playeringame[consoleplayer]) return;
		let p = players[consoleplayer];
		if (!p) return;
		Actor pawn = p.mo;
		if (!pawn || pawn.health <= 0) return;

		double stillMps = FloatOf(cvStill, 0.3);
		double needMps  = FloatOf(cvThrust, 2.0);
		double ageCap   = FloatOf(cvPeakAge, 150.0);
		int    repeat   = int(FloatOf(cvRepeat, 12.0));

		for (int hand = 0; hand < 2; hand++)
		{
			if (OpenPalm(pawn, hand)) openFor[hand]++;
			else openFor[hand] = 0;

			// STILL IS MEASURED ON THE SAME PEAK, not on the current sample: a
			// hand that twitched 200 ms ago has not been still, and the peak is
			// the only reading that remembers that.
			double along = ThrustAlongHand(pawn, hand);
			Vector3 vel = level.HandVelAtPoint(hand, (0, 0, 0), RS_HAND_PEAK);
			double upm = 32.0;
			let c = CVar.GetCVar("vr_vunits_per_meter", null);
			if (c) upm = max(c.GetFloat(), 0.0001);
			double speed = ((vel.x, vel.y, vel.z * level.pixelstretch) / upm).Length();
			if (speed < stillMps) stillFor[hand]++;
			else stillFor[hand] = 0;

			if (level.maptime - lastImpulse[hand] < repeat) continue;
			if (ageCap > 0 && level.HandPeakAgeMs(hand) > ageCap) continue;
			if (along < needMps) continue;

			lastImpulse[hand] = level.maptime;
			Fire(hand, along);
		}
	}

	// THE SAME SHAPE AS rsg_matched: an index and a hundredths-of-a-unit
	// magnitude, so a listener wires this up the way it already wires a shape
	// and nothing has to learn a second convention.
	//
	//   arg0  the hand, 0 main, 1 off
	//   arg1  the speed along the hand, in hundredths of a metre a second
	//   arg2  reserved, 0
	//
	// INTEGER HUNDREDTHS, so the number is identical on every machine and
	// nothing depends on anyone's float formatting -- the same reason
	// RS_HandNet sends a thrown object's velocity as thousandths.
	//
	// A CONSUMER MUST STILL DECIDE WHAT THIS MEANS. The event says a hand moved
	// fast along its own axis. It does not say a power fired, and it carries no
	// claim about netplay: it was measured from local hardware, so a consumer
	// that turns it into damage has to travel its own decision as a command.
	private void Fire(int hand, double alongMps)
	{
		if (BoolOf(cvDebug, false))
			Console.Printf("\c[Gold]rsg: thrust, %s hand, %.2f m/s along it",
				hand == HAND_MAIN ? "main" : "off", alongMps);
		SendNetworkEvent("rsg_thrust", hand, int(round(alongMps * 100.0)), 0);
	}
}
