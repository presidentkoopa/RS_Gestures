// BOTH HANDS AT ONCE -- the gesture kind that is a RELATIONSHIP, not a hand.
//
// RSG_Matcher recognises a SHAPE: a path the main hand drew, normalised and
// warped against templates. RSG_Signals answers what ONE hand is doing right
// now: open, closed, still, thrusting along its own axis. Neither can see the
// third kind, and it is the one several two-handed powers are made of --
//
//   BOTH HANDS SWEPT DOWN PAST THE HIPS, together.
//   BOTH HANDS THROWN OUTWARD FROM THE CHEST, diverging.
//   BOTH PALMS HELD OUT, open and still.
//
// It is not a shape: there are two paths, the matcher reads one ring, and the
// identity of the gesture is not in either path's outline but in the two
// happening AT ONCE. It is not a pose either: a pose is one tic's worth of
// fields and says nothing about the other hand's timing. So it is a third
// detector beside the other two, and the per-hand queries in RSG_Signals are
// its parts rather than its competition -- the open-palm test below is that
// file's, called, not copied.
//
// ---------------------------------------------------------------------------
// THE WHOLE DIFFICULTY IS THE WORD "TOGETHER", and it is the only thing in
// here worth arguing about.
//
// Two hands that sweep down 400 ms apart are two gestures. The same two hands
// 60 ms apart are one. Nobody can guess the number that divides those -- it is
// a property of a particular person's arms -- so it is `rsg_two_window_ms`, in
// REAL milliseconds, and it is on a slider in the menu because the person who
// has to find it is wearing a headset and has no keyboard.
//
// AND THE COMPARISON IS NOT "BOTH PASSED THE TEST ON THE SAME TIC". The stamp
// kept per hand below is WHEN THE MOVEMENT HAPPENED, not when this handler
// noticed it: Level.HandPeakAgeMs says how long ago that hand's fastest instant
// was, so `now - age` is the real time of the movement itself, and comparing
// two of those compares the two MOVEMENTS. Comparing the tics they were noticed
// on would fold the peak ring's own quarter second of lag into the tolerance,
// and the window would then have to be opened wide enough to cover that lag --
// which is to say wide enough to accept two deliberately separate sweeps. The
// symptom would be a two-hand gesture that fires off one hand plus a twitch.
//
// REAL SECONDS THROUGHOUT, never maptime. Level.RealSeconds() is the clock a
// controller lives on. Slowing the world is something this engine does
// (LevelLocals.SetTimeScale), so a tolerance counted in map tics would mean a
// different real tolerance at every time scale: at a fifth speed the player's
// two hands would have to arrive within a fifth of the window, which is not a
// thing a person can do, and the gesture would simply stop working in slow
// motion with nothing in the log.
//
// ---------------------------------------------------------------------------
// MEASURED IN METRIC SPACE, AND RELATIVE TO THE HEAD. Both halves matter and
// they fail differently.
//
//   METRIC, because map space is anisotropic: the vertical is metres times
//   vr_vunits_per_meter and then DIVIDED by level.pixelstretch
//   (vk_openxrdevice.cpp, GetRawHmdHeightInMapUnit), so a vertical threshold in
//   map units is about a fifth off a horizontal one. These gestures are mostly
//   vertical, which is the worst case: a downward sweep tested in map units
//   needs a visibly different effort from a sideways one. The conversion is
//   RSG_Signals.Metric(), which is where this family keeps it.
//
//   HEAD-RELATIVE, because "past the hips" and "from the chest" are places on a
//   body, not heights in a room. Against world Z they would be a different
//   gesture for a tall player, an unreachable one for a short player, and
//   nothing at all for someone sitting down -- which is how a lot of this gets
//   played. Everything below measures from HmdPos, so the only thing a player's
//   height changes is how far their own hands have to travel.
//
// Hand positions come from Level.HandPos, not from AttackPos and not from the
// capture ring: the engine's own note on HandPos says to use it "for anything a
// hand DECIDES", because AttackPos is the replicated shooting point and in a
// netgame is nowhere near the hand. RSG_Capture samples AttackPos, which is
// right for the matcher (a shape normalised against the head is the same shape
// either way) and wrong for a threshold measured against a hip.
//
// ---------------------------------------------------------------------------
// ANNOUNCE, DO NOT DECIDE. `rsg_pair` carries an index and a magnitude, the
// same shape as `rsg_matched` and `rsg_thrust`, and it carries no claim about
// what the gesture MEANS. Both hands went down together; whether that is a
// Force jump, a heave, a two-handed block or nothing at all is the consumer's
// to decide, and three consumers may read the same event differently.
//
// IT DOES NOT CARRY THE GEOMETRY, deliberately, and that is the same rule
// rsg_thrust set: the heading of the sweep is local hardware, the event is seen
// by every machine, and an int argument cannot hold a direction honestly. A
// consumer that needs to know WHICH WAY the hands threw reads the hands itself
// on the machine that has them and sends its own event, exactly as RS_Force
// does for a push.
//
// NETPLAY. Every read here is this machine's own XR runtime and none of it is
// on the wire. Detect locally, travel ONE event, and a consumer applies it for
// that event's player -- never for consoleplayer. Nothing here consumes playsim
// randomness, so a machine that never sees these hands is not left behind.
//
// NO HAPTICS AND NO SOUND. The matcher buzzes its mode open and shut because a
// mode is a state the player has to know he is in. This is not a mode, and a
// detector that rewarded the player for a gesture would be deciding that the
// gesture meant something.
//
// ---------------------------------------------------------------------------
// TRAPS THIS FILE IS SHAPED AROUND, past the two rsg_capture.zs already lists:
//
//   A ZERO STAMP IS A TIME. ZScript zero-fills fields, and Level.RealSeconds()
//   starts a map near zero, so stamps left at their default would read as "both
//   hands armed at the start of the level" for the whole of the first window.
//   They are set to NEVER instead, in OnRegister and again on every map load.
//
//   HandPeakAgeMs RETURNS -1 WHEN THERE IS NO PEAK AT ALL, which is less than
//   any cap and therefore passes an upper-bound test. A hand with no history is
//   not a fresh hand, so it is refused explicitly.
//
//   Level.HandPos IS (0,0,0) WITH NO CONTROLLER -- the engine says to check it
//   rather than trust the origin. Without that check a flat-screen player has
//   two hands at the map origin, a metre below a head that is somewhere else,
//   and both of them are permanently "past the hips".

class RSG_TwoHand : EventHandler
{
	// The same hand numbers as Level.HandVelAtPoint, the capture ring and
	// RSG_Signals, so nothing in this family ever converts.
	const HAND_MAIN = 0;
	const HAND_OFF  = 1;

	// WHICH TWO-HAND GESTURE FIRED -- arg0 of rsg_pair. New kinds are added at
	// the end, never inserted, because a consumer stores these numbers.
	const PAIR_DOWN  = 0;   // both hands swept down past the hips
	const PAIR_APART = 1;   // both hands thrown outward from the chest
	const PAIR_PALMS = 2;   // both palms open, held out, still

	// A TIME THAT HAS NOT HAPPENED YET. See the zero-stamp trap above.
	const NEVER = -1000.0;

	// WHEN EACH HAND'S MOVEMENT HAPPENED, in real seconds, and how big it was.
	// The stamp is the peak's own time (`now - age`), not the tic it was seen.
	//
	// THE DOWN SWEEP KEEPS ITS MAGNITUDE AND THE OUTWARD THROW DOES NOT, which
	// is not an oversight: a sweep's magnitude is a property of ONE hand, so the
	// weaker hand's own number is the honest one and it has to be remembered
	// from the instant that hand qualified. How fast the hands are coming APART
	// is a property of the pair and of no hand, so it is measured once, when
	// they are judged together, and never stored.
	private double downAt[2];
	private double downMps[2];
	private double apartAt[2];

	// A MOVEMENT FROM BEFORE THE LAST ANNOUNCEMENT CANNOT CAUSE ANOTHER ONE.
	//
	// CLEARING THE STAMPS IS NOT CONSUMPTION, and the comment that said it was
	// is corrected below. The peak ring keeps reporting the SAME fastest
	// instant for as long as it is inside vr_hand_window_ms, so the tic after
	// an announcement re-arms from the identical movement and the pair passes
	// again. Only the refire lockout stood between one sweep and a stream of
	// events, and `rsg_two_repeat_ms` reaches 0 on its own slider, where there
	// is no lockout at all.
	//
	// SO A HAND MAY ONLY ARM FROM A PEAK THAT HAPPENED AFTER THAT KIND LAST
	// ANNOUNCED -- saidAt below, which already holds exactly that time. One
	// field, two jobs: how long ago we spoke, and which movements are stale
	// because of it.
	//
	// AND IT NEEDS A TOLERANCE, which comparing two peak times would not have
	// made obvious. A stamp is `RealSeconds() - HandPeakAgeMs/1000`: the first
	// term steps on the TIC clock and the second slides on the RENDER clock, so
	// one fixed ring entry's stamp jitters by up to a frame from tic to tic, and
	// HandPeakAgeMs is 0 exactly while the hand is still accelerating -- which
	// leaves no slack at all for the jitter to be judged against. A peak less
	// than one tic newer than the announcement is the same movement; SAME_PEAK_S
	// is that, 0.03 s, one tic at 35 Hz.
	const SAME_PEAK_S = 0.03;

	// WHEN EACH PALM WENT OUT, and how long they have BOTH been out, which is
	// counted from the later of the two -- a pose is "together" when the second
	// hand joins it, and there is nothing to tolerance about that.
	private double palmsAt[2];
	private double palmsHeldFor;
	private bool   palmsSaid;

	// WHEN EACH KIND LAST FIRED, in real seconds. One human sweep passes the
	// test on many consecutive tics, and this is what makes it one
	// announcement -- twice over: it is the refire lockout's clock AND the line
	// a peak has to be newer than before a hand may arm from it at all. The
	// second job is the one that does the work; see SAME_PEAK_S above.
	//
	// The literal 3 is the three PAIR_ constants above -- a fixed array's size
	// has to be a plain constant expression, so it is written out rather than
	// derived.
	private double saidAt[3];

	private CVar cvEnabled;
	private CVar cvDebug;
	private CVar cvWindow;
	private CVar cvAge;
	private CVar cvRepeat;
	private CVar cvDownMps;
	private CVar cvDownFrac;
	private CVar cvHip;
	private CVar cvApart;
	private CVar cvChest;
	private CVar cvChestR;
	private CVar cvFront;
	private CVar cvHold;
	private CVar cvStill;
	// THE ENGINE'S OWN PEAK WINDOW, not ours: vr_hand_window_ms is the ring
	// VRHandPeakIndex searches (hw_vrmodes.cpp:1954, 250 ms), so it is the
	// oldest a peak can possibly be. Needed because `rsg_two_age` of 0 means
	// "do not cap the age" and the staleness bound then has to come from
	// somewhere real -- see liveS below.
	private CVar cvPeakWin;

	static RSG_TwoHand Get()
	{
		return RSG_TwoHand(EventHandler.Find("RSG_TwoHand"));
	}

	// ---- THE FRAME EVERYTHING IS MEASURED IN ------------------------------
	//
	// WHERE A MAP POINT IS RELATIVE TO THE PLAYER'S HEAD, IN METRES: still on
	// the map's own X and Y axes, which is all the two impulse tests need --
	// "below the hips" and "away from the chest" do not care which way the
	// player is facing.
	//
	// STATIC, like the RSG_Signals queries, so a consumer can ask the same
	// question this handler asks without finding the handler or switching it on.
	static Vector3 HeadMetric(Actor pawn, Vector3 mapPoint)
	{
		if (!pawn) return (0, 0, 0);
		return RSG_Signals.Metric(mapPoint - pawn.HmdPos);
	}

	// ...AND THE SAME POINT IN THE BODY'S OWN FRAME: x forward, y left, z up,
	// metres. This is what "held out in front of you" needs, and it is the
	// matcher's body-relative convention (rsg_match.zs, RSG_Normalizer) applied
	// to this tic instead of to a ring sample.
	//
	// THE ROTATION HAPPENS IN MAP SPACE, BEFORE THE CONVERSION, and that is not
	// an accident: a rotation is only a rotation where the axes it mixes have
	// the same scale. X and Y do; Z does not, and the yaw rotation never
	// touches Z. Rotating a metric vector would be equally safe for the same
	// reason, and rotating anything about X or Y in either space would not be.
	static Vector3 BodyMetric(Actor pawn, Vector3 mapPoint)
	{
		if (!pawn) return (0, 0, 0);
		Vector3 d = mapPoint - pawn.HmdPos;
		// Un-rotate by head yaw about Z, degrees, as the matcher does.
		double cs = cos(-pawn.HmdYaw);
		double sn = sin(-pawn.HmdYaw);
		Vector3 turned = (d.x * cs - d.y * sn, d.x * sn + d.y * cs, d.z);
		return RSG_Signals.Metric(turned);
	}

	// IS THIS HAND BEING TRACKED. (0,0,0) is the engine's "no controller", and
	// it is a position no real hand holds.
	static bool HandLive(int hand)
	{
		Vector3 h = level.HandPos(hand);
		return h.Length() > 0.0;
	}

	// HOW FRESH THIS HAND'S FASTEST INSTANT IS, in real seconds, or NEVER when
	// there is no peak or it is older than `maxAgeMs`. The -1 is the trap:
	// "no peak at all" is a smaller number than any cap and would pass an
	// upper-bound test on its own.
	static double PeakTime(int hand, double maxAgeMs)
	{
		double age = level.HandPeakAgeMs(hand);
		if (age < 0) return NEVER;
		if (maxAgeMs > 0 && age > maxAgeMs) return NEVER;
		return level.RealSeconds() - (age / 1000.0);
	}

	// ---- THE POSE: BOTH PALMS OUT -----------------------------------------
	//
	// OPEN, STILL, AND IN FRONT OF THE CHEST, for one hand. Three separate
	// conditions because there are three separate ways of not holding a palm
	// out, and a player who fails one of them deserves to be able to find out
	// which from the debug line rather than by waving harder.
	//
	//   OPEN is RSG_Signals.OpenPalm -- the two capacitive touch bits plus the
	//   grip and trigger travel. It is that file's and is not copied here; the
	//   hardware ceiling it documents (two touch bits, no finger curl) is why
	//   "palms out" is a gesture this engine can see at all and "two fingers
	//   out" is not.
	//
	//   STILL is measured on the PEAK sample and against `rsg_still_mps` -- the
	//   same reading and the same cvar as RSG_Signals' own stillness. A second
	//   number for the same idea would drift from the first, and the player
	//   would be given two dials that both mean "how still is still".
	//
	//   OUT IN FRONT is body-relative: at least `frontM` metres forward of the
	//   head and no lower than the hip line. Forward of the HEAD rather than of
	//   the chest because the head is the thing this engine publishes; the
	//   difference is a few centimetres of a shoulder and it is inside the
	//   slider's own range.
	static bool PalmsOutHand(Actor pawn, int hand, double frontM, double hipM, double stillMps)
	{
		if (!pawn || !HandLive(hand)) return false;
		if (!RSG_Signals.OpenPalm(pawn, hand)) return false;

		Vector3 vel = RSG_Signals.Metric(level.HandVelAtPoint(hand, (0, 0, 0), RS_HAND_PEAK));
		if (vel.Length() >= stillMps) return false;

		Vector3 rel = BodyMetric(pawn, level.HandPos(hand));
		return rel.x >= frontM && rel.z >= -hipM;
	}

	// HOW LONG BOTH PALMS HAVE BEEN OUT, in real seconds, 0 when they are not.
	//
	// THE EVENT IS THE ONSET AND THIS IS THE SUSTAIN, and a held power needs
	// both: a barrier that exists while the palms are out cannot be driven by an
	// edge, and a barrier that re-fired its event every tic would be a different
	// mod's problem by Tuesday. Needs the handler, because a duration is state.
	double PalmsOutSeconds() const
	{
		return palmsHeldFor;
	}

	// ---- CVARS ------------------------------------------------------------
	//
	// LOOKED UP LAZILY, WITH THE PLAYER, and retried while null. These are user
	// cvars: a user cvar fetched before the player exists comes back null, and a
	// null cached forever reads exactly like the feature being switched off with
	// nothing in the log. rsg_capture.zs paid for that lesson and rsg_match.zs
	// keeps the shape; this is the same shape.
	private void CacheCVars()
	{
		// BOUNDS BEFORE THE INDEX, and in that order: playeringame[] is a fixed
		// array and an out-of-range read is a VM abort that takes the map with
		// it. rsg_signals.zs checks it this way round; this did not, and the
		// caller's own bounds check ran AFTER this function.
		if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS) return;
		if (!playeringame[consoleplayer]) return;
		let p = players[consoleplayer];
		if (!p) return;

		if (cvEnabled == null)  cvEnabled  = CVar.GetCVar("rsg_twohand", p);
		if (cvDebug == null)    cvDebug    = CVar.GetCVar("rsg_debug", p);
		if (cvWindow == null)   cvWindow   = CVar.GetCVar("rsg_two_window_ms", p);
		if (cvAge == null)      cvAge      = CVar.GetCVar("rsg_two_age", p);
		if (cvRepeat == null)   cvRepeat   = CVar.GetCVar("rsg_two_repeat_ms", p);
		if (cvDownMps == null)  cvDownMps  = CVar.GetCVar("rsg_two_down_mps", p);
		if (cvDownFrac == null) cvDownFrac = CVar.GetCVar("rsg_two_down_frac", p);
		if (cvHip == null)      cvHip      = CVar.GetCVar("rsg_two_hip_m", p);
		if (cvApart == null)    cvApart    = CVar.GetCVar("rsg_two_apart_mps", p);
		if (cvChest == null)    cvChest    = CVar.GetCVar("rsg_two_chest_m", p);
		if (cvChestR == null)   cvChestR   = CVar.GetCVar("rsg_two_chest_r", p);
		if (cvFront == null)    cvFront    = CVar.GetCVar("rsg_two_front_m", p);
		if (cvHold == null)     cvHold     = CVar.GetCVar("rsg_two_hold_ms", p);
		if (cvStill == null)    cvStill    = CVar.GetCVar("rsg_still_mps", p);
		if (cvPeakWin == null)  cvPeakWin  = CVar.GetCVar("vr_hand_window_ms", p);
	}

	private double FloatOf(CVar c, double fallback)
	{
		return (c != null) ? c.GetFloat() : fallback;
	}
	private bool BoolOf(CVar c, bool fallback)
	{
		return (c != null) ? c.GetBool() : fallback;
	}

	private void ClearStamps()
	{
		for (int h = 0; h < 2; h++)
		{
			downAt[h]  = NEVER;
			downMps[h] = 0.0;
			apartAt[h] = NEVER;
			palmsAt[h] = NEVER;
		}
		for (int k = 0; k < 3; k++)
			saidAt[k] = NEVER;

		palmsHeldFor = 0.0;
		palmsSaid = false;
	}

	override void OnRegister()
	{
		ClearStamps();
	}

	// A NEW MAP IS A NEW SET OF HANDS. Level.RealSeconds() restarts with the
	// level, so a stamp carried across would be a stamp from the future.
	override void WorldLoaded(WorldEvent e)
	{
		ClearStamps();
	}

	// ---- THE TICK ---------------------------------------------------------
	//
	// WorldTick, not WorldStep, and that is deliberate: this runs once per REAL
	// tic whatever the world clock is doing, which is the only rate at which a
	// hand can be watched. A per-step detector would sample the hands a fifth as
	// often in slow motion and miss the fastest instant of every sweep.
	override void WorldTick()
	{
		CacheCVars();

		// OFF BY DEFAULT, and separately from both rsg_enabled and rsg_signals.
		// The statics above keep answering with this off -- they read nothing
		// but engine fields -- so what this switch buys is the held-pose
		// counter and the events, not the service.
		if (!BoolOf(cvEnabled, false))
		{
			// SWITCHED OFF MID-SESSION IS ALSO A WAY OUT, and the guard is here
			// only so that a mod nobody has switched this on for pays two
			// comparisons a tic rather than a loop.
			//
			// palmsSaid IS PART OF THE TEST, not decoration: a duration of
			// exactly 0.0 is reachable (rsg_two_hold_ms at 0 latches on the tic
			// the second palm arrives), and on that path the latch would survive
			// the switch being turned off and back on, so the onset the consumer
			// is waiting for would never be sent again.
			if (palmsHeldFor != 0.0 || palmsSaid) ClearStamps();
			return;
		}

		if (consoleplayer < 0 || consoleplayer >= MAXPLAYERS
			|| !playeringame[consoleplayer])
		{
			ClearStamps();
			return;
		}

		let p = players[consoleplayer];
		Actor pawn = null;
		if (p) pawn = p.mo;

		// EVERY WAY OUT CLEARS THE STATE, and that is not tidiness. The pose
		// duration is a LIVE claim a consumer reads -- a barrier that exists
		// while the palms are out -- so leaving it standing when the hands stop
		// being readable means the barrier stays up after the player has taken
		// the headset off, died, or walked into a cutscene. Nothing below is
		// expensive and the correct answer when the hands are unknown is zero,
		// not "whatever it was last time".
		//
		// Both hands or nothing, too: every gesture here is a relationship, and
		// a relationship with one hand in it is not a weaker version of itself.
		if (!pawn || pawn.health <= 0
			|| !HandLive(HAND_MAIN) || !HandLive(HAND_OFF))
		{
			ClearStamps();
			return;
		}

		double now      = level.RealSeconds();
		double windowS  = max(FloatOf(cvWindow, 120.0), 0.0) / 1000.0;
		double ageMs    = FloatOf(cvAge, 180.0);
		double repeatS  = max(FloatOf(cvRepeat, 500.0), 0.0) / 1000.0;
		double needDown = FloatOf(cvDownMps, 2.0);
		double downFrac = clamp(FloatOf(cvDownFrac, 0.5), 0.0, 1.0);
		double hipM     = FloatOf(cvHip, 0.60);
		double needApart = FloatOf(cvApart, 2.0);
		double chestM   = FloatOf(cvChest, 0.40);
		double chestR   = FloatOf(cvChestR, 0.50);
		double frontM   = FloatOf(cvFront, 0.25);
		double holdS    = max(FloatOf(cvHold, 400.0), 0.0) / 1000.0;
		double stillMps = FloatOf(cvStill, 0.3);

		// ---- per hand, and nothing is decided yet -------------------------
		for (int hand = 0; hand < 2; hand++)
		{
			double peakAt = PeakTime(hand, ageMs);
			Vector3 vel = RSG_Signals.Metric(level.HandVelAtPoint(hand, (0, 0, 0), RS_HAND_PEAK));
			Vector3 rel = HeadMetric(pawn, level.HandPos(hand));
			double speed = vel.Length();

			// DOWN PAST THE HIPS. Two conditions and a direction test:
			//
			//   The hand is BELOW the hip line NOW. The peak may be up to
			//   `rsg_two_age` old, so where the hand is now is where the sweep
			//   ENDED -- which is what "swept down PAST the hips" means. Hip
			//   height is the one number shared with the palms pose below, so
			//   the two can never disagree about where a hip is.
			//
			//   And the movement is mostly DOWNWARD, not merely downward-ish:
			//   `rsg_two_down_frac` of the hand's whole speed. A speed
			//   threshold with no direction test is the mistake the QuestSaber
			//   logged against its own Push -- a sword fight is nothing but
			//   fast arm movement, so a fast forward lunge with a bit of droop
			//   in it would cast this all day.
			//
			// AND THE MOVEMENT HAPPENED AFTER THE LAST DOWN ANNOUNCEMENT: the
			// ring hands the same fastest instant back for as long as it is in
			// its window, so without this the sweep just announced re-arms on
			// the very next tic. See SAME_PEAK_S above.
			double downMove = -vel.z;
			bool downish = speed > 0.0001 && (downMove / speed) >= downFrac;
			if (peakAt > NEVER && peakAt > saidAt[PAIR_DOWN] + SAME_PEAK_S
				&& downMove >= needDown && downish && rel.z <= -hipM)
			{
				downAt[hand] = peakAt;
				downMps[hand] = downMove;
			}

			// OUTWARD FROM THE CHEST. The chest is `rsg_two_chest_m` below the
			// head, straight down -- which ignores how far a leaning player's
			// chest has swung forward, and that is a few centimetres against a
			// radius of half a metre.
			//
			// NEAR THE CHEST is a ceiling, not a shell: the peak is up to
			// `rsg_two_age` old, so by the time the throw is seen the hand has
			// already left. The number that matters is that a hand thrown from
			// the HIP or from over the head is not this gesture.
			Vector3 fromChest = (rel.x, rel.y, rel.z + chestM);
			double chestDist = fromChest.Length();
			// HALF the pair's threshold per hand, because the threshold is on
			// the PAIR: two hands each going outward at half of it are
			// separating at all of it. Asking each hand for the full number
			// would quietly be asking for twice the gesture.
			double needHand = needApart * 0.5;
			if (peakAt > NEVER && peakAt > saidAt[PAIR_APART] + SAME_PEAK_S
				&& chestDist > 0.0001 && chestDist <= chestR)
			{
				Vector3 chestDir = fromChest.Unit();
				double outward = vel dot chestDir;
				if (outward >= needHand)
					apartAt[hand] = peakAt;
			}

			// PALMS OUT. A pose, so no peak and no window -- just whether it
			// holds, and from when.
			if (PalmsOutHand(pawn, hand, frontM, hipM, stillMps))
			{
				if (palmsAt[hand] <= NEVER)
					palmsAt[hand] = now;
			}
			else
			{
				palmsAt[hand] = NEVER;
			}
		}

		// ---- and now the pair ---------------------------------------------

		// HOW LONG A STAMP STAYS GOOD: the age cap plus the window, and that sum
		// is not a fudge.
		//
		// A stamp is as much as `rsg_two_age` old the moment it is written (the
		// peak it names already happened), and its partner is allowed to arrive
		// up to `rsg_two_window_ms` later and be as stale again. So the first
		// hand's stamp has to survive both, or a pair performed at the very edge
		// of the tolerance would be thrown away for being old.
		//
		// WITHOUT THIS A STAMP NEVER DIES, because the window is the DIFFERENCE
		// between two stamps and that difference does not grow with time. Two
		// hands that swept down an hour ago would still read as together.
		//
		// AND `rsg_two_age` OF 0 MEANS "DO NOT CAP THE AGE" -- which the cvar
		// and its own slider both offer. Deriving the bound from the cap alone
		// then collapsed it to the window, 120 ms, while PeakTime was handing
		// back peaks up to the engine's whole ring old: every stamp was thrown
		// away for being stale and TWO OF THE THREE GESTURES STOPPED FIRING,
		// with nothing in the log and the slider reading like a tolerance. So
		// when the cap is off the bound is the engine's own peak window, which
		// is the oldest a peak can actually be, rather than a guess.
		double capMs = (ageMs > 0.0) ? ageMs : max(FloatOf(cvPeakWin, 250.0), 0.0);
		double liveS = (capMs / 1000.0) + windowS;

		// TOGETHER: the two movements, not the two tics they were seen on.
		if (Together(downAt[HAND_MAIN], downAt[HAND_OFF], windowS, now, liveS))
		{
			// THE WEAKER HAND IS THE MAGNITUDE. Taking the faster one would let
			// one hand thrown hard and one hand barely qualifying read as a
			// full-strength two-hand sweep, which is the gesture being half
			// performed and fully rewarded.
			double mag = min(downMps[HAND_MAIN], downMps[HAND_OFF]);
			if (Announce(PAIR_DOWN, mag, now, repeatS))
			{
				// CONSUMED, both hands -- and that only half mattered. The
				// stamp is rewritten from the same ring entry on the next tic,
				// so what actually stops a stream is the arm guard above
				// refusing a peak older than this announcement; this clear is
				// what stops it inside the SAME tic's remaining work.
				downAt[HAND_MAIN] = NEVER;
				downAt[HAND_OFF]  = NEVER;
			}
		}

		if (Together(apartAt[HAND_MAIN], apartAt[HAND_OFF], windowS, now, liveS))
		{
			// DIVERGING, as a pair, and this is the test that tells a repulse
			// from a two-handed shove. Both hands moving away from the chest is
			// not enough on its own: two hands thrust FORWARD together are both
			// moving away from the chest and are not coming apart at all. The
			// rate the gap between them is opening is, in metres a second:
			// d/dt |p0 - p1| is the relative velocity along the line between
			// them, which needs no history and is exact.
			Vector3 gap = level.HandPos(HAND_MAIN) - level.HandPos(HAND_OFF);
			Vector3 sep = RSG_Signals.Metric(gap);
			double rate = 0.0;
			if (sep.Length() > 0.0001)
			{
				Vector3 v0 = RSG_Signals.Metric(level.HandVelAtPoint(HAND_MAIN, (0, 0, 0), RS_HAND_PEAK));
				Vector3 v1 = RSG_Signals.Metric(level.HandVelAtPoint(HAND_OFF, (0, 0, 0), RS_HAND_PEAK));
				Vector3 sepDir = sep.Unit();
				Vector3 closing = v0 - v1;
				rate = closing dot sepDir;
			}

			if (rate >= needApart && Announce(PAIR_APART, rate, now, repeatS))
			{
				apartAt[HAND_MAIN] = NEVER;
				apartAt[HAND_OFF]  = NEVER;
			}
		}

		// THE POSE COUNTS FROM THE LATER HAND. "Both palms out for 400 ms" is
		// 400 ms of BOTH, so the clock starts when the second palm arrives; the
		// first hand getting there early earns nothing, which is what stops a
		// hand resting open at your side from being half of the gesture all day.
		if (palmsAt[HAND_MAIN] > NEVER && palmsAt[HAND_OFF] > NEVER)
		{
			palmsHeldFor = now - max(palmsAt[HAND_MAIN], palmsAt[HAND_OFF]);

			// AN EDGE, NOT A STREAM, and the latch is cleared by the pose
			// breaking rather than by a timer: a pose that re-announced itself
			// every `rsg_two_repeat_ms` would make a consumer's "did it start"
			// unanswerable. PalmsOutSeconds() is how a held power follows it.
			//
			// THE LATCH IS SET BY THE SEND, NOT BEFORE IT. SendNetworkEvent
			// returns false having sent nothing when gamestate is not GS_LEVEL
			// (events.zs, above the declaration), and latching ahead of it means
			// the one onset a held power is waiting for is dropped on exactly
			// the frames a level is changing, with nothing to retry it.
			if (!palmsSaid && palmsHeldFor >= holdS)
			{
				if (Announce(PAIR_PALMS, palmsHeldFor, now, 0.0))
					palmsSaid = true;
			}
		}
		else
		{
			palmsHeldFor = 0.0;
			palmsSaid = false;
		}

		Telemetry(pawn, hipM, chestM, chestR, frontM, stillMps);
	}

	// BOTH ARMED, BOTH STILL CURRENT, AND WITHIN THE WINDOW OF EACH OTHER.
	//
	// NEVER fails the first test on its own, so an unarmed hand can never be
	// half of a pair -- which is why the sentinel is a time in the deep past
	// rather than a zero, and why there is no second "is it armed" flag to get
	// out of step with the stamp itself.
	private bool Together(double a, double b, double windowS, double now, double liveS) const
	{
		if (a <= NEVER || b <= NEVER) return false;
		if ((now - a) > liveS || (now - b) > liveS) return false;
		return abs(a - b) <= windowS;
	}

	// ---- ANNOUNCING -------------------------------------------------------
	//
	// THE SAME SHAPE AS rsg_matched AND rsg_thrust: an index and a hundredths
	// magnitude, so a consumer wires a two-hand gesture up the way it already
	// wires a shape or a thrust and nothing has to learn a third convention.
	//
	//   arg0  which gesture: PAIR_DOWN, PAIR_APART, PAIR_PALMS
	//   arg1  its magnitude in hundredths of its own unit --
	//           PAIR_DOWN   the SLOWER hand's downward speed, m/s
	//           PAIR_APART  how fast the hands are coming apart, m/s
	//           PAIR_PALMS  how long both palms have been out, seconds
	//   arg2  reserved, 0. The heading is deliberately not here; see the header.
	//
	// INTEGER HUNDREDTHS, so the number is identical on every machine and
	// nothing depends on anyone's float formatting -- the same reason rsg_thrust
	// sends a speed in hundredths and RS_HandNet sends a velocity in
	// thousandths.
	//
	// Returns WHETHER IT WAS ACTUALLY SENT, so the caller knows whether to
	// consume the stamps that produced it. `repeatS` of 0 skips the lockout,
	// which is what a latched pose wants.
	//
	// AND THAT MEANS CHECKING THE SEND. SendNetworkEvent returns false having
	// sent nothing when gamestate is not GS_LEVEL or GS_TITLELEVEL -- the
	// declaration in events.zs says so in capitals, because the engine used to
	// declare it void and threw the refusal away. Throwing it away here meant
	// arming the lockout and consuming the player's sweep for an event that was
	// never written. A refusal leaves the stamps standing instead, and the next
	// tic tries again off the same peak, which is the correct answer for a
	// gesture: the player performed it once and it should announce once.
	private bool Announce(int which, double mag, double now, double repeatS)
	{
		if (which < 0 || which >= 3) return false;
		if (repeatS > 0.0 && (now - saidAt[which]) < repeatS) return false;

		if (!SendNetworkEvent("rsg_pair", which, int(round(mag * 100.0)), 0))
			return false;

		saidAt[which] = now;

		if (BoolOf(cvDebug, false))
			Console.Printf("\c[Gold]rsg: pair %s, %.2f", KindName(which), mag);

		return true;
	}

	private String KindName(int which) const
	{
		if (which == PAIR_DOWN)  return "both hands down";
		if (which == PAIR_APART) return "both hands apart";
		if (which == PAIR_PALMS) return "both palms out";
		return "unknown";
	}

	// ---- WHY IT DID NOT FIRE ----------------------------------------------
	//
	// A detector that only speaks when it succeeds is untestable in a headset:
	// the player waves, nothing happens, and there is no way to tell a threshold
	// that is too high from a hand that is not being tracked from a cvar that
	// came back null. So under rsg_debug this prints the live numbers once a
	// second, in the units the sliders are in, and every one of them can be read
	// against the slider that gates it.
	private void Telemetry(Actor pawn, double hipM, double chestM, double chestR,
						   double frontM, double stillMps)
	{
		if (!BoolOf(cvDebug, false)) return;
		if ((level.realtime % TICRATE) != 0) return;

		Vector3 r0 = HeadMetric(pawn, level.HandPos(HAND_MAIN));
		Vector3 r1 = HeadMetric(pawn, level.HandPos(HAND_OFF));
		Vector3 v0 = RSG_Signals.Metric(level.HandVelAtPoint(HAND_MAIN, (0, 0, 0), RS_HAND_PEAK));
		Vector3 v1 = RSG_Signals.Metric(level.HandVelAtPoint(HAND_OFF, (0, 0, 0), RS_HAND_PEAK));
		Vector3 b0 = BodyMetric(pawn, level.HandPos(HAND_MAIN));
		Vector3 b1 = BodyMetric(pawn, level.HandPos(HAND_OFF));

		// Vector literals are built into locals before anything is asked of
		// them: a method call on a parenthesised vector literal is the kind of
		// expression that parses in one engine and not the next, and this line
		// only exists to be read.
		Vector3 c0 = (r0.x, r0.y, r0.z + chestM);
		Vector3 c1 = (r1.x, r1.y, r1.z + chestM);
		Vector3 between = r0 - r1;          // the head cancels; the gap is the gap
		double gapM = between.Length();
		int open0 = RSG_Signals.OpenPalm(pawn, HAND_MAIN) ? 1 : 0;
		int open1 = RSG_Signals.OpenPalm(pawn, HAND_OFF) ? 1 : 0;

		// THREE LINES, EACH ONE GESTURE'S OWN NUMBERS, in slider units. One
		// format string per call: ZScript has no implicit concatenation of
		// adjacent string literals, so a wrapped format is a syntax error.
		Console.Printf("rsg pair down: speed %.2f/%.2f m/s (need in slider)  height %.2f/%.2f m, hip line -%.2f m  peak age %.0f/%.0f ms",
			-v0.z, -v1.z, r0.z, r1.z, hipM,
			level.HandPeakAgeMs(HAND_MAIN), level.HandPeakAgeMs(HAND_OFF));

		Console.Printf("rsg pair apart: from chest %.2f/%.2f m (within %.2f)  hands %.2f m apart",
			c0.Length(), c1.Length(), chestR, gapM);

		Console.Printf("rsg pair palms: open %d/%d  forward %.2f/%.2f m (need %.2f)  speed %.2f/%.2f m/s (still under %.2f)  both out for %.2f s",
			open0, open1, b0.x, b1.x, frontM,
			v0.Length(), v1.Length(), stillMps, palmsHeldFor);
	}
}
