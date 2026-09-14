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

// A named chain of already-registered templates' ids, matched in order
// within a bounded time window between consecutive steps.
//
// Deliberately a SIDE OBSERVATION on top of ordinary matching, not a
// replacement path: each step keeps firing its own rsg_matched exactly as it
// does standing alone, so a template already bound to its own action (the
// grenade-summon demo, say) keeps working by itself AND can also be one link
// of a chain. The chain only adds a second, separate event when the whole
// thing completes -- nothing about single-gesture use has to change to
// support sequences existing.
//
// Built by pushing onto stepIds directly rather than through a constructor
// taking an array parameter -- ZScript's array-parameter semantics across a
// call boundary are exactly the kind of thing this codebase has been burned
// by guessing about before (`out Vector3` crashing the JIT is the standing
// example), so this sidesteps needing to trust one this file has not proven.
class RSG_Sequence play
{
	name id;
	name book;
	Array<name> stepIds;
	int maxInterStepTics;
}

// Stroke segmentation: OFF-HAND POSE, not a button anywhere.
//
// Two earlier designs, both replaced for the same reason -- a real signal
// beats a heuristic guessing one:
//   v1 ran DTW every tic against a sliding window, gated by a rearm cooldown
//      and a minimum-extent floor. Three heuristics approximating one thing
//      a window cannot know on its own: when did the gesture start and end.
//   v2 delimited the stroke on GripHeldMain -- hold to draw, release to
//      match, per MageVR-Reborn's published design (README only, no source;
//      vr-reference-study-unified.md Part 6). Real signal, but the wrong
//      button: RS_WorldHands' grab claims that same press whenever the hand
//      is near anything grabbable, entirely independent of gesture mode.
//
// v3 moves the signal to the OFF hand's POSE instead of any button on either
// hand: hold the off hand above the head, and that alone means "gesture mode
// is live" for as long as it is held -- entry and every stroke's start/stop
// ride on the same continuous hold, the same way entry-into-first-stroke
// already worked in v2. The drawing (main) hand never touches a button or
// grip at all, so it cannot collide with grabbing, weapon fire, or a
// reload's own button reads -- there is nothing left on that hand to
// collide WITH. The off hand's own pose is deliberately the same "raised
// above the head" shape the old main-hand entry used, not a new one to
// invent and re-litigate.
//
// Stated tradeoff, same as always: an off hand busy holding this pose cannot
// also be doing anything else -- including a second, independent gesture,
// if that is ever wanted. The alternative (infer start/stop from the main
// hand's own motion, freeing both hands) was considered and set aside for
// now: it trades a deliberate, explicit signal for one inferred from
// velocity, which is the same species of guess v1 already proved fragile.
class RSG_Matcher : EventHandler
{
	private Array<RSG_Template> templates;
	private Array<RSG_Sequence> sequences;
	private Array<int> seqProgress;     // parallel to sequences
	private Array<int> seqLastStepTic;  // parallel to sequences
	private name activeBook;

	private bool modeActive;
	private int entryHeld;
	private int idleTics;
	private bool drawing;
	private int drawStartTic;
	private bool wasPoseMid;
	private bool seeded;
	private Array<double> dtwCost;
	private RSG_Recorder recorder;
	private bool customsLoaded;

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

	void RegisterSequence(RSG_Sequence s)
	{
		if (s == null || s.stepIds.Size() == 0)
			return;

		sequences.Push(s);
		seqProgress.Push(0);
		seqLastStepTic.Push(0);
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

	// Same idea for a listener on rsg_sequence_matched.
	name GetSequenceId(int index)
	{
		if (index < 0 || index >= sequences.Size() || sequences[index] == null)
			return 'none';

		return sequences[index].id;
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

	// Built-in demo gestures: a downward stroke and its mirror, in front of
	// the body. They exist so there is something to perform and watch fire
	// before any recording tool does; a real library replaces them.
	//
	// The pair is deliberate, not padding: DTW scores the path in time order,
	// so a stroke and its exact reverse are two genuinely different shapes to
	// match against, not the same one performed twice -- which is what makes
	// them useful as the two links of the demo sequence below, rather than a
	// chain that would trivially complete on any single stroke either way.
	private void SeedDemoTemplates()
	{
		if (seeded)
			return;

		seeded = true;

		let down = RSG_Stroke(new("RSG_Stroke"));
		down.Init();
		let up = RSG_Stroke(new("RSG_Stroke"));
		up.Init();

		for (int i = 0; i < RSG_Stroke.STEPS; ++i)
		{
			double t = double(i) / double(RSG_Stroke.STEPS - 1);
			// In front of the head, sweeping from above eye level to waist.
			down.SetPoint(i, (18.0, 0.0, 16.0 - 56.0 * t));
			// The same two points, travelled the other way.
			up.SetPoint(i, (18.0, 0.0, -40.0 + 56.0 * t));
		}

		RegisterTemplate(RSG_Template.Create("downstroke", "default", down, 0, 0));
		RegisterTemplate(RSG_Template.Create("upstroke", "default", up, 0, 0));
		activeBook = "default";

		// Demo sequence: downstroke then upstroke, within 2 seconds of each
		// other. Nothing listens for rsg_sequence_matched yet -- proving the
		// chain-tracking fires at all is the point, same as downstroke alone
		// proved single-template matching before any demo action existed.
		let seq = RSG_Sequence(new("RSG_Sequence"));
		seq.id = "down_up";
		seq.book = "default";
		seq.stepIds.Push("downstroke");
		seq.stepIds.Push("upstroke");
		seq.maxInterStepTics = 70;
		RegisterSequence(seq);
	}

	override void OnRegister()
	{
		recorder = RSG_Recorder(new("RSG_Recorder"));
		SeedDemoTemplates();
	}

	// --------------------------------------------------------------- mode --

	private void OpenMode()
	{
		modeActive = true;
		idleTics = 0;

		// Entry is held on the off-hand pose; carry that same hold straight into
		// the first stroke rather than requiring a separate signal once mode
		// opens. One continuous hold: raise the off hand, keep it there while
		// the main hand sweeps, drop it when done.
		drawing = true;
		drawStartTic = level.maptime;
		wasPoseMid = true;

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

	// The one signal for everything: off hand raised above the head. No
	// button, no grip -- so the drawing (main) hand is never touching an
	// input that anything else in this mod family could also be reading.
	// Distinct enough not to happen by accident, and it needs no finger
	// tracking, which this engine does not have.
	private bool OffHandDrawPose(PlayerPawn pawn)
	{
		return pawn.OffhandPos.z > pawn.HmdPos.z;
	}

	// --------------------------------------------------------------- tick --

	override void WorldTick()
	{
		CacheCVars();

		// Before the capture check, on purpose: recorded gestures should
		// already be registered the moment gestures are switched on, not
		// only after they have been on for a tic.
		if (!customsLoaded && playeringame[consoleplayer])
			LoadCustomTemplates();

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
			if (OffHandDrawPose(pawn))
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

		bool pose = OffHandDrawPose(pawn);

		if (drawing)
		{
			int span = level.maptime - drawStartTic;
			int maxSpan = IntOf(cvWindow, 70);

			// Dropping the pose ends the stroke normally. Hitting the cap ends
			// it too, without waiting for a drop that may not be coming -- an
			// arm left raised must not hold the ring's own history hostage
			// forever. Either way this is an EDGE, not a level: wasPoseMid
			// below stops the still-held cap case from restarting a stroke on
			// its very next tic with no drop in between.
			if (!pose || span >= maxSpan)
			{
				CompleteStroke(min(span, maxSpan));
				drawing = false;
			}

			wasPoseMid = pose;
			return;
		}

		// Between strokes: raise the off hand again to draw another, same as
		// entry did. Edge-triggered so a still-raised hand from a capped
		// stroke cannot immediately restart one.
		if (pose && !wasPoseMid)
		{
			drawing = true;
			drawStartTic = level.maptime;
		}
		wasPoseMid = pose;
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

		bool recording = recorder != null && recorder.IsRecording();

		if (stroke.Extent() < FloatOf(cvMinExtent, 8.0))
		{
			// Silent while matching -- a hand holding still is not a failed
			// gesture. Said aloud while recording, because there the player is
			// deliberately performing and a take that vanishes with no reason
			// looks exactly like the recorder being broken.
			if (recording)
				Say("rsg: take too small to count -- draw it bigger");

			return;
		}

		// A take is recorded INSTEAD of matched, not as well: matching a shape
		// against the library while you are still teaching it one would fire
		// whatever it happens to resemble on every single take.
		if (recording)
		{
			RecordTake(stroke);
			return;
		}

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

		AdvanceSequences(t.id);
	}

	// One matched template can be the next link of several sequences, or of
	// none -- checked against every registered chain, not just one.
	private void AdvanceSequences(name matchedId)
	{
		for (int i = 0; i < sequences.Size(); ++i)
		{
			let seq = sequences[i];
			if (seq == null || seq.book != activeBook)
				continue;

			// Stale progress expires rather than carrying forever -- a chain
			// half-drawn a minute ago must not silently complete just because
			// the right shape happens to come around again later.
			if (seqProgress[i] > 0 && (level.maptime - seqLastStepTic[i]) > seq.maxInterStepTics)
				seqProgress[i] = 0;

			if (matchedId != seq.stepIds[seqProgress[i]])
				continue;

			seqProgress[i]++;
			seqLastStepTic[i] = level.maptime;

			if (seqProgress[i] >= seq.stepIds.Size())
			{
				seqProgress[i] = 0;

				if (DebugOn())
					Console.Printf("rsg: sequence '%s' completed", seq.id);

				// Same shape as rsg_matched: index only, a listener maps it
				// back through GetSequenceId.
				SendNetworkEvent("rsg_sequence_matched", i, 0, 0);
			}
		}
	}

	// ----------------------------------------------------------- recording --

	// Not gated on rsg_debug, unlike every other print in this file: during
	// a recording the player is waiting on these lines to know what to do.
	private void Say(String msg)
	{
		Console.Printf("%s", msg);
	}

	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Player != consoleplayer || recorder == null)
			return;

		if (e.Name == "rsg_rec_start")
		{
			int startSlot = e.Args[0];
			if (startSlot < 1 || startSlot > RSG_Recorder.SLOT_COUNT)
				return;

			recorder.Start(startSlot);
			Say(String.Format("rsg: recording slot %d -- raise your off hand, draw the shape, drop it. %d times or more.",
				startSlot, RSG_Recorder.MIN_TAKES));

			let cap = RSG_Capture.Get();
			if (cap == null || !cap.IsCapturing())
				Say("rsg: gestures are switched off -- enable them first or nothing will record");
		}
		else if (e.Name == "rsg_rec_save")
		{
			SaveRecording();
		}
		else if (e.Name == "rsg_rec_cancel")
		{
			if (recorder.IsRecording())
				Say("rsg: recording cancelled, nothing saved");

			recorder.Stop();
		}
		else if (e.Name == "rsg_rec_clear")
		{
			ClearSlot(e.Args[0]);
		}
	}

	// Once, the first tic a player exists -- a cvar fetched before then comes
	// back null, the same reason CacheCVars is lazy.
	private void LoadCustomTemplates()
	{
		customsLoaded = true;

		for (int loadSlot = 1; loadSlot <= RSG_Recorder.SLOT_COUNT; ++loadSlot)
		{
			let cv = CVar.GetCVar(RSG_Recorder.CVarName(loadSlot), players[consoleplayer]);
			if (cv == null)
				continue;

			let loaded = RSG_Recorder.Deserialize(cv.GetString(), RSG_Recorder.SlotId(loadSlot));
			if (loaded != null)
				RegisterOrReplace(loaded);
		}
	}

	// In place, so a slot re-recorded mid-session keeps its index: a listener
	// mapping rsg_matched's index through GetTemplateId never sees the registry
	// shift underneath it.
	private void RegisterOrReplace(RSG_Template tmpl)
	{
		for (int ri = 0; ri < templates.Size(); ++ri)
		{
			if (templates[ri] != null && templates[ri].id == tmpl.id)
			{
				templates[ri] = tmpl;
				return;
			}
		}

		templates.Push(tmpl);
	}

	private void RecordTake(RSG_Stroke stroke)
	{
		int count = recorder.AddTake(stroke);
		if (count < 0)
		{
			Say(String.Format("rsg: %d takes is the most one recording keeps -- save it or cancel",
				RSG_Recorder.MAX_TAKES));
			return;
		}

		// Felt, not just printed: the text is easy to miss mid-motion, and a
		// buzz in the drawing hand is unmistakably "that one counted."
		level.VRHaptic(RSG_Capture.HAND_MAIN, 0.4, 40.0);

		if (count < RSG_Recorder.MIN_TAKES)
			Say(String.Format("rsg: take %d recorded -- %d more needed", count, RSG_Recorder.MIN_TAKES - count));
		else
			Say(String.Format("rsg: take %d recorded -- save now, or keep going for a steadier gesture", count));
	}

	// THE TEMPLATE IS THE MEDOID TAKE, NOT AN AVERAGE.
	//
	// The medoid is the take with the least total DTW distance to all the
	// others. A point-by-point average looks like the obvious choice and is
	// wrong here: takes are resampled by TIME, so point 12 of a slow take and
	// point 12 of a fast one can be different parts of the shape, and averaging
	// them smears it into something nobody drew. The medoid is a shape the
	// player actually performed.
	//
	// Tolerance comes from how far the other takes sat from it. A steady
	// performer gets a tight gesture, a loose one a forgiving gesture, and
	// neither touches a slider. The farthest counted take is set to land just
	// inside the confidence gate, plus a quarter as margin.
	private void SaveRecording()
	{
		if (!recorder.IsRecording())
		{
			Say("rsg: nothing is being recorded");
			return;
		}

		int n = recorder.TakeCount();
		if (n < RSG_Recorder.MIN_TAKES)
		{
			Say(String.Format("rsg: need %d takes to save, have %d", RSG_Recorder.MIN_TAKES, n));
			return;
		}

		// DTW is symmetric, so each pair is measured once and mirrored.
		Array<double> dist;
		dist.Resize(n * n);
		for (int a = 0; a < n; ++a)
		{
			dist[a * n + a] = 0;
			for (int b = a + 1; b < n; ++b)
			{
				double pairCost = DTW(recorder.TakeAt(a), recorder.TakeAt(b));
				dist[a * n + b] = pairCost;
				dist[b * n + a] = pairCost;
			}
		}

		int medoid = 0;
		double medoidSum = -1;
		for (int m = 0; m < n; ++m)
		{
			double rowSum = 0;
			for (int k = 0; k < n; ++k)
				rowSum += dist[m * n + k];

			if (medoidSum < 0 || rowSum < medoidSum)
			{
				medoidSum = rowSum;
				medoid = m;
			}
		}

		// One fumbled take must not loosen the whole gesture. With three or
		// more other takes to compare against, the single farthest is left out
		// of the tolerance if it sits beyond twice the average of the rest.
		double worst = 0;
		int worstIndex = -1;
		double total = 0;
		for (int w = 0; w < n; ++w)
		{
			if (w == medoid)
				continue;

			double toMedoid = dist[medoid * n + w];
			total += toMedoid;
			if (toMedoid > worst)
			{
				worst = toMedoid;
				worstIndex = w;
			}
		}

		double spread = worst;
		bool dropped = false;
		int others = n - 1;
		if (others >= 3)
		{
			double restAverage = (total - worst) / double(others - 1);
			if (worst > 2.0 * restAverage)
			{
				spread = 0;
				for (int r = 0; r < n; ++r)
				{
					if (r == medoid || r == worstIndex)
						continue;

					double kept = dist[medoid * n + r];
					if (kept > spread)
						spread = kept;
				}
				dropped = true;
			}
		}

		// Capped at 0.9: a gate of 1.0 would demand infinite tolerance.
		double gate = FloatOf(cvConfidence, 0.35);
		if (gate > 0.9)
			gate = 0.9;

		double tol = spread / (1.0 - gate) * 1.25;
		if (tol < 4.0)
			tol = 4.0;
		if (tol > 60.0)
			tol = 60.0;

		let chosen = recorder.TakeAt(medoid);
		int saveSlot = recorder.ActiveSlot();
		name slotName = RSG_Recorder.SlotId(saveSlot);

		let cv = CVar.GetCVar(RSG_Recorder.CVarName(saveSlot), players[consoleplayer]);
		if (cv != null)
			cv.SetString(RSG_Recorder.Serialize(chosen, tol));
		else
			Say("rsg: slot cvar missing -- kept for this session only, it will not survive a restart");

		RegisterOrReplace(RSG_Template.Create(slotName, "default", chosen, tol, 0));

		level.VRHaptic(RSG_Capture.HAND_MAIN, 1.0, 150.0);
		Say(String.Format("rsg: saved '%s' from %d takes -- tolerance %.1f, takes varied up to %.1f%s",
			slotName, n, tol, spread, dropped ? " (one outlier take ignored)" : ""));

		recorder.Stop();
	}

	private void ClearSlot(int clearSlot)
	{
		if (clearSlot < 1 || clearSlot > RSG_Recorder.SLOT_COUNT)
			return;

		let cv = CVar.GetCVar(RSG_Recorder.CVarName(clearSlot), players[consoleplayer]);
		if (cv != null)
			cv.SetString("");

		// The stroke is nulled rather than the entry deleted: deleting shifts
		// every later index, and CompleteStroke already skips a null stroke.
		name slotName = RSG_Recorder.SlotId(clearSlot);
		for (int ci = 0; ci < templates.Size(); ++ci)
		{
			if (templates[ci] != null && templates[ci].id == slotName)
				templates[ci].stroke = null;
		}

		Say(String.Format("rsg: slot %d cleared", clearSlot));
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
