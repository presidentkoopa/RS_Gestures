// Per-hand ring buffer of VR controller motion, sampled once per playsim tic.
//
// Gesture recognition needs a short history of how a hand moved, and nothing
// remembers one -- every VR pose field on Actor holds the current tic only.
// This stores the last few seconds of what those fields already say. It reads
// nothing new and writes no engine state: AttackPos, MainHandRoll, OffhandPos,
// HmdPos and the grip fields are all published natively every tic, before any
// ZScript Tick() runs.
//
// Kept separate from the matcher because it is not gesture-specific. Anything
// wanting to know how a hand has been moving -- a throw, a swing, a flourish --
// can read the ring without loading a recogniser it has no use for.
//
// Head pose is stored alongside every hand sample deliberately. Normalising a
// gesture to be body-relative, so it matches regardless of which way the player
// is facing, needs the head pose from the same instant as the hand pose.
// Keeping world-space hand positions alone would make that unreconstructable
// afterwards.
//
// TWO TRAPS THIS FILE IS SHAPED AROUND:
//
// ZSCRIPT IDENTIFIERS ARE CASE-INSENSITIVE. A field `count` and a method
// `Count()` in the same class are the same name, and the compiler stops with
// "Attempt to redefine" -- fatally, and globally, taking every pk3 after this
// one in the load order down with it. The storage fields below are therefore
// named so they cannot collide with the accessors: sampleCount/ringSize/
// btnState rather than count/capacity/buttons. Cost a broken engine boot once.
//
// Vectors are returned by value, never through `out` parameters: `out Vector3`
// crashes the ZScript JIT at class-load ("Unknown REGT value passed to
// EmitPARAM"), which the engine's VR_INTERACTION_PLAN.md documents as having
// cost this project hours more than once.

class RSG_Ring play
{
	// Sample age 0 is the most recent, matching the native RingBuffer in the
	// engine's src/common/utility/TSQueue.h so both ends index history the same
	// way round.
	private Array<double> posX;
	private Array<double> posY;
	private Array<double> posZ;
	private Array<double> handPitch;
	private Array<double> handYaw;
	private Array<double> handRoll;
	private Array<double> headX;
	private Array<double> headY;
	private Array<double> headZ;
	private Array<double> headYaw;
	private Array<double> headPitch;
	private Array<double> headRoll;
	private Array<int> btnState;
	private Array<int> sampleTic;

	private int ringSize;
	private int writePos;
	private int sampleCount;

	void Init(int cap)
	{
		ringSize = cap;
		writePos = -1;
		sampleCount = 0;

		posX.Resize(cap);
		posY.Resize(cap);
		posZ.Resize(cap);
		handPitch.Resize(cap);
		handYaw.Resize(cap);
		handRoll.Resize(cap);
		headX.Resize(cap);
		headY.Resize(cap);
		headZ.Resize(cap);
		headYaw.Resize(cap);
		headPitch.Resize(cap);
		headRoll.Resize(cap);
		btnState.Resize(cap);
		sampleTic.Resize(cap);
	}

	void Push(Vector3 hand, double pitch, double yaw, double roll,
			  Vector3 hmd, double hmdYaw, double hmdPitch, double hmdRoll,
			  int btn, int tic)
	{
		if (ringSize <= 0)
			return;

		writePos = (writePos + 1) % ringSize;

		posX[writePos] = hand.x;
		posY[writePos] = hand.y;
		posZ[writePos] = hand.z;
		handPitch[writePos] = pitch;
		handYaw[writePos] = yaw;
		handRoll[writePos] = roll;
		headX[writePos] = hmd.x;
		headY[writePos] = hmd.y;
		headZ[writePos] = hmd.z;
		headYaw[writePos] = hmdYaw;
		headPitch[writePos] = hmdPitch;
		headRoll[writePos] = hmdRoll;
		btnState[writePos] = btn;
		sampleTic[writePos] = tic;

		if (sampleCount < ringSize)
			sampleCount++;
	}

	void Clear()
	{
		writePos = -1;
		sampleCount = 0;
	}

	int Count()
	{
		return sampleCount;
	}

	int Capacity()
	{
		return ringSize;
	}

	private int IndexFor(int age)
	{
		if (age < 0 || age >= sampleCount)
			return -1;

		int i = writePos - age;
		while (i < 0)
			i += ringSize;

		return i;
	}

	bool Valid(int age)
	{
		return IndexFor(age) >= 0;
	}

	Vector3 HandPos(int age)
	{
		int i = IndexFor(age);
		if (i < 0)
			return (0, 0, 0);

		return (posX[i], posY[i], posZ[i]);
	}

	// (pitch, yaw, roll) in degrees.
	Vector3 HandAngles(int age)
	{
		int i = IndexFor(age);
		if (i < 0)
			return (0, 0, 0);

		return (handPitch[i], handYaw[i], handRoll[i]);
	}

	Vector3 HeadPos(int age)
	{
		int i = IndexFor(age);
		if (i < 0)
			return (0, 0, 0);

		return (headX[i], headY[i], headZ[i]);
	}

	// (pitch, yaw, roll) in degrees.
	Vector3 HeadAngles(int age)
	{
		int i = IndexFor(age);
		if (i < 0)
			return (0, 0, 0);

		return (headPitch[i], headYaw[i], headRoll[i]);
	}

	int ButtonsAt(int age)
	{
		int i = IndexFor(age);
		return (i < 0) ? 0 : btnState[i];
	}

	int TicAt(int age)
	{
		int i = IndexFor(age);
		return (i < 0) ? 0 : sampleTic[i];
	}
}

class RSG_Capture : EventHandler
{
	// 3 seconds at TICRATE (35). Long enough for a multi-stroke gesture, short
	// enough that walking the whole buffer stays cheap.
	const CAPTURE_TICS = 105;

	const HAND_MAIN = 0;
	const HAND_OFF = 1;

	private RSG_Ring mainRing;
	private RSG_Ring offRing;
	private CVar cvEnabled;

	static RSG_Capture Get()
	{
		return RSG_Capture(EventHandler.Find("RSG_Capture"));
	}

	bool IsCapturing()
	{
		if (cvEnabled == null)
			return false;

		return cvEnabled.GetBool();
	}

	RSG_Ring GetRing(int hand)
	{
		return (hand == HAND_OFF) ? offRing : mainRing;
	}

	private void EnsureReady()
	{
		if (mainRing == null)
		{
			mainRing = RSG_Ring(new("RSG_Ring"));
			mainRing.Init(CAPTURE_TICS);
		}

		if (offRing == null)
		{
			offRing = RSG_Ring(new("RSG_Ring"));
			offRing.Init(CAPTURE_TICS);
		}

		// Looked up lazily rather than in OnRegister: a cvar fetched before the
		// player exists comes back null, and a null cached forever reads exactly
		// like the feature being switched off, with nothing in the log.
		if (cvEnabled == null && playeringame[consoleplayer])
			cvEnabled = CVar.GetCVar("rsg_enabled", players[consoleplayer]);
	}

	override void WorldTick()
	{
		EnsureReady();

		if (!IsCapturing())
			return;

		// Only the local player: controller poses are read from this machine's
		// XR runtime, and usercmd_t carries no off-hand pose at all, so nobody
		// else's hands are knowable here.
		if (!playeringame[consoleplayer])
			return;

		let pawn = players[consoleplayer].mo;
		if (pawn == null)
			return;

		int btn = players[consoleplayer].cmd.buttons;
		// REAL tics, not map tics. WorldTick runs once per engine tic whatever
		// the world clock is doing (src/events.h: "WorldTick keeps real time"),
		// so this ring gains exactly one sample per real tic. Stamping those
		// samples with maptime made the stamp disagree with the ring's own
		// spacing the moment slow motion was running, and stop advancing at all
		// with the world frozen.
		int tic = level.realtime;

		// MainHandRoll, not AttackRoll: AttackRoll is force-zeroed every tic to
		// stay deterministic across peers (there is no weaponroll in the wire
		// protocol), so sampling it would flatten a whole axis out of every
		// main-hand gesture and the matcher would quietly be worse for it.
		mainRing.Push(pawn.AttackPos, pawn.AttackPitch, pawn.AttackAngle, pawn.MainHandRoll,
					  pawn.HmdPos, pawn.HmdYaw, pawn.HmdPitch, pawn.HmdRoll,
					  btn, tic);

		offRing.Push(pawn.OffhandPos, pawn.OffhandPitch, pawn.OffhandAngle, pawn.OffhandRoll,
					 pawn.HmdPos, pawn.HmdYaw, pawn.HmdPitch, pawn.HmdRoll,
					 btn, tic);
	}
}
