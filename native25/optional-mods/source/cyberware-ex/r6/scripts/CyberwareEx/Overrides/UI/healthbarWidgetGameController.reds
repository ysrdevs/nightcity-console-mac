import CyberwareEx.*

// Overrides the installed Cyberdeck check that's used to determine
// if the memory bar should be displayed under the health bar.
@replaceMethod(healthbarWidgetGameController)
protected final const func IsCyberdeckEquipped() -> Bool {
    return CyberwareHelper.IsCyberdeckEquipped(this.GetPlayerControlledObject());
}
