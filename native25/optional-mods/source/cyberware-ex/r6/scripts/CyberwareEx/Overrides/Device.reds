import CyberwareEx.*

// Overrides how installed Cyberdeck check works for some of the hacking events related to devices.
@replaceMethod(Device)
protected final const func IsCyberdeckEquippedOnPlayer() -> Bool {
    return CyberwareHelper.IsCyberdeckEquipped(GetPlayer(this.GetGame()));
}
