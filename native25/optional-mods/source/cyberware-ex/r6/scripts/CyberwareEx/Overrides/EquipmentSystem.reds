
// Overrides the helper that determines if the player has Cyberdeck installed.
@replaceMethod(EquipmentSystem)
public final static func IsCyberdeckEquipped(owner: ref<GameObject>) -> Bool {
    return GameInstance.GetStatsSystem(owner.GetGame()).GetStatBoolValue(Cast(owner.GetEntityID()), gamedataStatType.HasCyberdeck);
}
