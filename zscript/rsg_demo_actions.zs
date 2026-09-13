// Demo wiring only: downstroke -> swap the main hand to RS_Grenade's universal
// grenade, if it's installed. This exists to prove the recognise-then-act
// pipeline end to end with something visible, not because the recogniser
// should know what any gesture is "for" -- it shouldn't, and doesn't: Fire()
// in rsg_match.zs sends only an index and a confidence.
//
// A NAME VARIABLE, NEVER A LITERAL, WHERE A CLASS<T> IS EXPECTED.
//
// FindInventory/GiveInventory take class<Inventory>, and a STRING OR NAME
// LITERAL passed where a class<T> is expected is resolved and validated AT
// COMPILE TIME, against the WHOLE LOAD's class table -- this shipped once as
// pmo.FindInventory("RS_VRGrenade") and failed with "Unknown class name
// 'RS_VRGrenade'" the moment RS_Grenade.pk3 was not in that boot's load order.
// That is the exact "fatal and global if the referenced pk3 is absent or
// loads later" trap RS_Grenade's own zscript.txt describes for a direct class
// reference -- a literal argument here is that same trap, not an exception to
// it, whatever the argument's declared type looks like.
//
// The fix is the engine's own pattern for this, in scriptutil.zs:31 --
// ScriptUtil.GiveInventory, the native backing for ACS's "give" command, which
// by definition must tolerate a class name unknown at compile time. It works
// by assigning a NAME VARIABLE (never a literal in that position) to a
// Class<Actor>: `Class<Actor> info = type;` where type is a Name parameter.
// That conversion is a genuine runtime lookup and returns null for an unknown
// class instead of refusing to compile. Routing the name through a local
// variable here, the same way, is what actually makes this optional.
class RSG_DemoActions : EventHandler
{
	override void NetworkProcess(ConsoleEvent e)
	{
		if (e.Name != "rsg_matched")
			return;

		let matcher = RSG_Matcher.Get();
		if (matcher == null)
			return;

		if (matcher.GetTemplateId(e.Args[0]) != 'downstroke')
			return;

		if (!playeringame[consoleplayer])
			return;

		let pmo = players[consoleplayer].mo;
		if (pmo == null)
			return;

		Name grenadeClassName = 'RS_VRGrenade';
		Class<Actor> grenadeClass = grenadeClassName;   // runtime lookup, null if absent
		if (grenadeClass == null || !(grenadeClass is 'Weapon'))
			return; // RS_Grenade not loaded -- nothing to swap to.

		let invClass = (class<Inventory>)(grenadeClass);
		let wpn = Weapon(pmo.FindInventory(invClass));
		if (wpn == null)
		{
			pmo.GiveInventory(invClass, 1);
			wpn = Weapon(pmo.FindInventory(invClass));
		}
		if (wpn == null)
			return;

		// hand 0 = main (matches RSG_Capture.HAND_MAIN, and matches the entry
		// gesture, which is main-hand-only). exactInstance: true, because this
		// specific instance is what was just given, not "any weapon whose
		// class matches" -- see the parameter's own comment in player.zs.
		pmo.MoveWeaponToHand(wpn, 0, true);
	}
}
