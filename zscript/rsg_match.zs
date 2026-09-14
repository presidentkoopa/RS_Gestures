// Normalisation, matching and gesture-mode state, on top of the capture ring.
//
// Strokes are passed around as objects rather than through `out` array
// parameters. ZScript's handling of dynamic arrays across call boundaries is
// awkward, and `out Vector3` is an outright JIT crash in this engine, so
// returning an object is the one shape that is unambiguously safe.

// A gesture path resampled to a fixed number of steps, in body-relative space.
//
// Body-relative means hand position minus head position, with the head's yaw
// rotated out. A gesture then matches the same whichever way the player is
// facing and wherever they are standing -- world space would make every
// template facing-specific and useless.
//
// Fixed step count is what lets a slow performance match a fast one at all:
// resampling to a constant length removes gross duration, and DTW then absorbs
// the uneven speed left inside the stroke.
class RSG_Stroke play
{
	const STEPS = 32;

	Array<double> x;
	Array<double> y;
	Array<double> z;

	void Init()
	{
		x.Resize(STEPS);
		y.Resize(STEPS);
		z.Resize(STEPS);
	}

	Vector3 Point(int i)
	{
		if (i < 0 || i >= STEPS)
			return (0, 0, 0);

		return (x[i], y[i], z[i]);
	}

	void SetPoint(int i, Vector3 p)
	{
		if (i < 0 || i >= STEPS)
			return;

		x[i] = p.x;
		y[i] = p.y;
		z[i] = p.z;
	}

	// Furthest distance from the stroke's first point. A hand holding still
	// draws a tiny tight path that would otherwise match almost any template,
	// so callers use this as a floor.
	double Extent()
	{
		Vector3 origin = Point(0);
		double best = 0;

		for (int i = 1; i < STEPS; ++i)
		{
			double d = (Point(i) - origin).Length();
			if (d > best)
				best = d;
		}

		return best;
	}
}

class RSG_Normalizer play
{
	// Resample the most recent `span` tics of `ring` into a fixed-step,
	// body-relative stroke. Returns null when there is not enough history yet.
	static RSG_Stroke Build(RSG_Ring ring, int span)
	{
		if (ring == null)
			return null;

		int avail = ring.Count();
		if (avail < 2)
			return null;

		if (span > avail)
			span = avail;

		if (span < 2)
			return null;

		let stroke = RSG_Stroke(new("RSG_Stroke"));
		stroke.Init();

		// Age runs backwards: age (span-1) is the oldest sample in the window
		// and age 0 the newest, so step 0 of the stroke is the start of the
		// motion and the path reads forwards in time.
		for (int i = 0; i < RSG_Stroke.STEPS; ++i)
		{
			double t = double(i) / double(RSG_Stroke.STEPS - 1);
			double sample = t * double(span - 1);

			int lo = int(sample);
			int hi = lo + 1;
			if (hi > span - 1)
				hi = span - 1;

			double frac = sample - double(lo);

			Vector3 a = BodyRelative(ring, (span - 1) - lo);
			Vector3 b = BodyRelative(ring, (span - 1) - hi);

			stroke.SetPoint(i, a * (1.0 - frac) + b * frac);
		}

		return stroke;
	}

	// Hand position relative to the head at that same instant, with the head's
	// yaw rotated out.
	static Vector3 BodyRelative(RSG_Ring ring, int age)
	{
		Vector3 hand = ring.HandPos(age);
		Vector3 head = ring.HeadPos(age);
		Vector3 headAng = ring.HeadAngles(age); // (pitch, yaw, roll)

		Vector3 d = hand - head;

		// Un-rotate by head yaw about Z (up, in Doom). ZScript trig takes
		// degrees, which is what the angle fields already are.
		double yaw = headAng.y;
		double cs = cos(-yaw);
		double sn = sin(-yaw);

		return (d.x * cs - d.y * sn, d.x * sn + d.y * cs, d.z);
	}
}

// One authored or recorded gesture, plus when it is allowed to match.
//
// Context gating is a virtual rather than a data field on purpose. The
// predicates worth writing -- hand empty, weapon holstered, near something
// usable, this book is open -- are game logic, and no engine-side enumeration
// of them would ever be complete. A mod subclasses this and answers for itself.
class RSG_Template play
{
	name id;
	name book;
	RSG_Stroke stroke;

	// Per-template overrides. Zero or less means "use the cvar", so a template
	// that does not care is unaffected when the player retunes globally.
	double tolerance;
	double minConfidence;

	static RSG_Template Create(name templateId, name bookName, RSG_Stroke path, double tol, double minConf)
	{
		let t = RSG_Template(new("RSG_Template"));
		t.id = templateId;
		t.book = bookName;
		t.stroke = path;
		t.tolerance = tol;
		t.minConfidence = minConf;
		return t;
	}

	virtual bool ContextValid(PlayerPawn pawn)
	{
		return true;
	}
}

// Stroke segmentation: BUTTON-DELIMITED, not a sliding window.
//
// The first cut of this matcher ran DTW every tic against the last
// rsg_window tics of the ring buffer, gated by a rearm cooldown after each
// fire and a minimum-extent floor to reject a hand holding still. Three
// separate heuristics, all approximating one thing a sliding window cannot
// know on its own: when did the gesture actually start and end.
//
// MageVR-Reborn's published design (README only, no source -- see
// vr-reference-study-unified.md Part 6) answers this directly: hold a button
// to trace, release to end the stroke. That is a real signal, not an
// approximation, and it deletes the rearm cooldown outright -- there is
// nothing to re-arm when a stroke only ever gets matched once, exactly when
// it completes.
//
// Reuses GripHeldMain rather than the trigger, deliberately: entry already
// holds grip (raise the hand, hold grip, mode opens), so drawing is the same
// grip carried straight through the downward sweep -- one continuous motion,
// release at the bottom to fire. The trigger stays free, so gesture mode
// does not fight the currently readied weapon's own fire button. Known
// tradeoff, stated rather than hidden: this means a gesture cannot itself be
// "squeeze the trigger" shaped, since that button is reserved.
class RSG_Matcher : EventHandler
{
	private Array<RSG_Template> templates;
	private name activeBook;

	private bool modeActive;
	private int entryHeld;
	private int idleTics;
	private bool drawing;
	private int drawStartTic;
	private bool wasGripMid;
	private bool seeded;
	private Array<double> dtwCost;

	private CVar cvDebug, cvEntryHold, cvIdleExit, cvWindow;
	private CVar cvTolerance, cvConfidence, cvMinExtent;

	static RSG_Matcher Get()
	{
		return RSG_Matcher(EventHandler.Find("RSG_Matcher"));
	}

	void RegisterTemplate(RSG_Template t)
	{
		if (t != null)
			templates.Push(t);
	}

	void SetBook(name bookName)
	{
		activeBook = bookName;
	}

	bool IsModeActive()
	{
		return modeActive;
	}

	// So a listener on rsg_matched can find out which template matched --
	// the event itself carries only the index, since network events are ints
	// only.
	name GetTemplateId(int index)
	{
		if (index < 0 || index >= templates.Size() || templates[index] == null)
			return 'none';

		return templates[index].id;
	}

	// ------------------------------------------------------------- cvars --

	private void CacheCVars()
	{
		if (!playeringame[consoleplayer])
			return;

		let p = players[consoleplayer];

		if (cvDebug == null)      cvDebug      = CVar.GetCVar("rsg_debug", p);
		if (cvEntryHold == null)  cvEntryHold  = CVar.GetCVar("rsg_entry_hold", p);
		if (cvIdleExit == null)   cvIdleExit   = CVar.GetCVar("rsg_idle_exit", p);
		if (cvWindow == null)     cvWindow     = CVar.GetCVar("rsg_window", p);
		if (cvTolerance == null)  cvTolerance  = CVar.GetCVar("rsg_tolerance", p);
		if (cvConfidence == null) cvConfidence = CVar.GetCVar("rsg_confidence", p);
		if (cvMinExtent == null)  cvMinExtent  = CVar.GetCVar("rsg_min_extent", p);
	}

	private bool DebugOn()
	{
		return cvDebug != null && cvDebug.GetBool();
	}

	private int IntOf(CVar c, int fallback)
	{
		return (c != null) ? c.GetInt() : fallback;
	}

	private double FloatOf(CVar c, double fallback)
	{
		return (c != null) ? c.GetFloat() : fallback;
	}

	// ---------------------------------------------------------- templates --

	// Built-in demo gesture: a downward stroke in front of the body. It exists
	// so there is something to perform and watch fire before any recording tool
	// does; a real library replaces it.
	private void SeedDemoTemplates()
	{
		if (seeded)
			return;

		seeded = true;

		let path = RSG_Stroke(new("RSG_Stroke"));
		path.Init();

		for (int i = 0; i < RSG_Stroke.STEPS; ++i)
		{
			double t = double(i) / double(RSG_Stroke.STEPS - 1);
			// In front of the head, sweeping from above eye level to waist.
			path.SetPoint(i, (18.0, 0.0, 16.0 - 56.0 * t));
		}

		RegisterTemplate(RSG_Template.Create("downstroke", "default", path, 0, 0));
		activeBook = "default";
	}

	override void OnRegister()
	{
		SeedDemoTemplates();
	}

	// --------------------------------------------------------------- mode --

	private void OpenMode()
	{
		modeActive = true;
		idleTics = 0;

		// Entry is held on grip; carry that same hold straight into the first
		// stroke rather than requiring a separate press once mode opens. One
		// continuous motion: raise, hold, sweep, release.
		drawing = true;
		drawStartTic = level.maptime;
		wasGripMid = true;

		if (DebugOn())
			Console.Printf("rsg: mode open");
	}

	private void CloseMode(String reason)
	{
		modeActive = false;
		entryHeld = 0;
		drawing = false;

		if (DebugOn())
			Console.Printf("rsg: mode closed (%s)", reason);
	}

	// Taking a hit cancels gesture mode: being interrupted mid-draw is exactly
	// when the player stopped meaning to draw.
	override void WorldThingDamaged(WorldEvent e)
	{
		if (!modeActive || e.Thing == null)
			return;

		if (!playeringame[consoleplayer])
			return;

		if (e.Thing == players[consoleplayer].mo)
			CloseMode("damaged");
	}

	// Entry pose: main hand raised above the head with grip held. Distinct
	// enough not to happen by accident, and it needs no finger tracking --
	// which this engine does not have.
	private bool EntryPoseHeld(PlayerPawn pawn)
	{
		if (!pawn.GripHeldMain)
			return false;

		return pawn.AttackPos.z > pawn.HmdPos.z;
	}

	// --------------------------------------------------------------- tick --

	override void WorldTick()
	{
		CacheCVars();

		let cap = RSG_Capture.Get();
		if (cap == null || !cap.IsCapturing())
		{
			if (modeActive)
				CloseMode("capture off");

			return;
		}

		if (!playeringame[consoleplayer])
			return;

		let pawn = players[consoleplayer].mo;
		if (pawn == null)
			return;

		if (!modeActive)
		{
			if (EntryPoseHeld(pawn))
			{
				entryHeld++;
				if (entryHeld >= IntOf(cvEntryHold, 18))
				{
					entryHeld = 0;
					OpenMode();
				}
			}
			else
			{
				entryHeld = 0;
			}

			return;
		}

		idleTics++;
		if (idleTics >= IntOf(cvIdleExit, 350))
		{
			CloseMode("idle");
			return;
		}

		bool grip = pawn.GripHeldMain;

		if (drawing)
		{
			int span = level.maptime - drawStartTic;
			int maxSpan = IntOf(cvWindow, 70);

			// Release ends the stroke normally. Hitting the cap ends it too,
			// without waiting for a release that may not be coming -- a stuck
			// or forgotten grip must not hold the ring's own history hostage
			// forever. Either way this is an EDGE, not a level: wasGripMid
			// below stops the still-held cap case from restarting a stroke on
			// its very next tic with no release in between.
			if (!grip || span >= maxSpan)
			{
				CompleteStroke(min(span, maxSpan));
				drawing = false;
			}

			wasGripMid = grip;
			return;
		}

		// Between strokes: press-and-hold grip again to draw another, same as
		// entry did. Edge-triggered so a still-held grip from a capped stroke
		// cannot immediately restart one.
		if (grip && !wasGripMid)
		{
			drawing = true;
			drawStartTic = level.maptime;
		}
		wasGripMid = grip;
	}

	private void CompleteStroke(int span)
	{
		let cap = RSG_Capture.Get();
		if (cap == null || !playeringame[consoleplayer])
			return;

		let pawn = players[consoleplayer].mo;
		if (pawn == null)
			return;

		let ring = cap.GetRing(RSG_Capture.HAND_MAIN);
		let stroke = RSG_Normalizer.Build(ring, span);
		if (stroke == null)
			return;

		if (stroke.Extent() < FloatOf(cvMinExtent, 8.0))
			return;

		int bestIndex = -1;
		double bestConfidence = 0;

		for (int i = 0; i < templates.Size(); ++i)
		{
			let t = templates[i];
			if (t == null || t.stroke == null)
				continue;

			// Gate before matching, always. It is far cheaper than a DTW pass,
			// and it is also the thing that stops an out-of-context gesture
			// from ever being a false positive in the first place.
			if (t.book != activeBook)
				continue;

			if (!t.ContextValid(pawn))
				continue;

			double conf = Confidence(stroke, t);
			double need = (t.minConfidence > 0) ? t.minConfidence : FloatOf(cvConfidence, 0.35);

			if (conf >= need && conf > bestConfidence)
			{
				bestConfidence = conf;
				bestIndex = i;
			}
		}

		if (bestIndex >= 0)
			Fire(bestIndex, bestConfidence);
	}

	private void Fire(int index, double confidence)
	{
		let t = templates[index];
		idleTics = 0;

		// %s takes a bare name directly -- no cast needed. scriptutil.zs:223
		// (Console.Printf("...%s...", type.GetClassName())) is the existing
		// precedent; GetClassName() returns Name, unconverted. `String(t.id)`
		// was a real bug (call to unknown function 'String'), not a fix.
		if (DebugOn())
			Console.Printf("rsg: matched '%s' (%.2f)", t.id, confidence);

		// Index rather than name: network events carry ints only. A listener
		// maps the index back through the registry it registered into.
		SendNetworkEvent("rsg_matched", index, int(confidence * 100), 0);
	}

	// -------------------------------------------------------------- match --

	private double Confidence(RSG_Stroke live, RSG_Template t)
	{
		double tol = (t.tolerance > 0) ? t.tolerance : FloatOf(cvTolerance, 14.0);
		if (tol <= 0)
			return 0;

		double avg = DTW(live, t.stroke);

		double conf = 1.0 - (avg / tol);
		if (conf < 0)
			conf = 0;
		if (conf > 1)
			conf = 1;

		return conf;
	}

	// Dynamic time warping: the cheapest honest way to say "same shape, drawn
	// at a different speed" without making the player match a tempo. Returns
	// average per-step cost along the best alignment.
	//
	// 32x32 cells per candidate per tic, against however few templates survive
	// the context gate -- which is the reason the gate runs first.
	private double DTW(RSG_Stroke a, RSG_Stroke b)
	{
		int n = RSG_Stroke.STEPS;
		int w = n + 1;

		// Held as a member and reused: a fresh 1089-element array 35 times a
		// second, per candidate, is pure garbage churn.
		if (dtwCost.Size() != w * w)
			dtwCost.Resize(w * w);

		double huge = 100000000.0;

		for (int i = 0; i <= n; ++i)
		{
			for (int j = 0; j <= n; ++j)
				dtwCost[i * w + j] = huge;
		}

		dtwCost[0] = 0;

		for (int i = 1; i <= n; ++i)
		{
			for (int j = 1; j <= n; ++j)
			{
				double d = (a.Point(i - 1) - b.Point(j - 1)).Length();

				double best = dtwCost[(i - 1) * w + (j - 1)];

				double up = dtwCost[(i - 1) * w + j];
				if (up < best)
					best = up;

				double left = dtwCost[i * w + (j - 1)];
				if (left < best)
					best = left;

				dtwCost[i * w + j] = d + best;
			}
		}

		// The best path through an n x n grid is at least n steps, so dividing
		// by n keeps scores comparable between templates.
		return dtwCost[n * w + n] / double(n);
	}
}
