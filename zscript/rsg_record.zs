// Recording a gesture by performing it, instead of typing its points in.
//
// The demo templates in rsg_match.zs are 32 points written out by hand. That
// does not scale past a straight line -- nobody can type a spiral. So a
// template can also be RECORDED: perform the same shape at least MIN_TAKES
// times, and the most typical take becomes the template while how much the
// takes disagreed becomes its tolerance. See RSG_Matcher.SaveRecording.
//
// This class holds takes and does storage only. The math that picks the
// typical take needs DTW, which lives in RSG_Matcher with its reusable cost
// buffer; a second copy of DTW here would be two things to keep in agreement.
//
// Persisted in user string cvars, one per slot, so a recording survives a
// restart. User scope because every other rsg_ cvar is and GetCVar is this
// mod's proven read path -- but a user cvar is userinfo, sent to other players
// when it changes. A saved slot is roughly 600 characters. Single-player is
// fine; a netgame has not been tried with one.
class RSG_Recorder play
{
	const SLOT_COUNT = 4;
	const MIN_TAKES = 3;
	const MAX_TAKES = 8;

	private int recSlot;                 // 0 = not recording
	private Array<RSG_Stroke> takes;

	bool IsRecording()
	{
		return recSlot > 0;
	}

	int ActiveSlot()
	{
		return recSlot;
	}

	int TakeCount()
	{
		return takes.Size();
	}

	RSG_Stroke TakeAt(int i)
	{
		if (i < 0 || i >= takes.Size())
			return null;

		return takes[i];
	}

	// Resize(0), not Clear(): Resize is what this mod already uses everywhere,
	// and dynamic-array methods are compiler intrinsics with no declaration to
	// check a guess against.
	void Start(int s)
	{
		recSlot = s;
		takes.Resize(0);
	}

	void Stop()
	{
		recSlot = 0;
		takes.Resize(0);
	}

	// The new take count, or -1 when already full.
	int AddTake(RSG_Stroke st)
	{
		if (st == null || takes.Size() >= MAX_TAKES)
			return -1;

		takes.Push(st);
		return takes.Size();
	}

	// Literals rather than a formatted String turned into a Name. Converting a
	// runtime String to a Name is exactly the kind of cast this mod has guessed
	// wrong about before (String(name) was a compile error), and four fixed
	// names need no conversion at all.
	static name SlotId(int s)
	{
		if (s == 1) return 'custom_1';
		if (s == 2) return 'custom_2';
		if (s == 3) return 'custom_3';
		if (s == 4) return 'custom_4';
		return 'none';
	}

	static String CVarName(int s)
	{
		return String.Format("rsg_custom_%d", s);
	}

	// "v1|tolerance|x,y,z|x,y,z|..." -- the tag first, so a future format can
	// be told apart from this one instead of misread as it.
	static String Serialize(RSG_Stroke st, double tol)
	{
		String s = String.Format("v1|%.2f", tol);

		for (int i = 0; i < RSG_Stroke.STEPS; ++i)
		{
			Vector3 p = st.Point(i);
			s.AppendFormat("|%.2f,%.2f,%.2f", p.x, p.y, p.z);
		}

		return s;
	}

	// Null for anything that is not exactly a v1 record of the right length. A
	// half-parsed stroke would still register and still match -- wrongly, and
	// with nothing to say why -- so any doubt at all rejects the whole slot.
	static RSG_Template Deserialize(String s, name id)
	{
		if (s.Length() == 0)
			return null;

		Array<String> parts;
		s.Split(parts, "|", TOK_SKIPEMPTY);
		if (parts.Size() != RSG_Stroke.STEPS + 2 || parts[0] != "v1")
			return null;

		double tol = parts[1].ToDouble();
		if (tol <= 0)
			return null;

		let st = RSG_Stroke(new("RSG_Stroke"));
		st.Init();

		Array<String> xyz;
		for (int i = 0; i < RSG_Stroke.STEPS; ++i)
		{
			xyz.Resize(0);
			parts[i + 2].Split(xyz, ",", TOK_SKIPEMPTY);
			if (xyz.Size() != 3)
				return null;

			st.SetPoint(i, (xyz[0].ToDouble(), xyz[1].ToDouble(), xyz[2].ToDouble()));
		}

		return RSG_Template.Create(id, "default", st, tol, 0);
	}
}
