module CyberwareEx

public struct ExpansionArea {
    public let equipmentArea: gamedataEquipmentArea;
    public let extraSlots: array<ExpansionSlot>;

    public static func Create(equipmentArea: gamedataEquipmentArea, extraSlots: array<ExpansionSlot>) -> ExpansionArea =
        ExpansionArea(equipmentArea, extraSlots)
}

public struct ExpansionSlot {
    public let requiredPerk: gamedataNewPerkType;
    public let requiredLevel: Int32;

    public static func Create(requiredPerk: gamedataNewPerkType, requiredLevel: Int32) -> ExpansionSlot =
        ExpansionSlot(requiredPerk, requiredLevel)
}

public struct AttachmentSlot {
    public let slotID: TweakDBID;
    public let slotName: CName;
    public let cyberwareType: CName;

    public static func Create(slotName: CName, cyberwareType: CName) -> AttachmentSlot =
        AttachmentSlot(TDBID.Create(NameToString(slotName)), slotName, cyberwareType)
}

public struct CyberwareRemapping {
    public let displayName: CName;
    public let cyberwareType: CName;

    public static func Create(recordID: TweakDBID, cyberwareType: CName) -> CyberwareRemapping =
        CyberwareRemapping(TweakDBInterface.GetLocKeyDefault(recordID + t".displayName"), cyberwareType)
}

public abstract class CyberwareConfig {
    public static func SlotExpansions() -> array<ExpansionArea> =
        IsCustomMode()
            ? GetCustomSlotExpansions()
            : CyberwareConfig.DefaultSlotExpansions()

    public static func DefaultSlotExpansions() -> array<ExpansionArea> =
        IsExtendedMode()
                ? CyberwareConfig.ExtendedSlotExpansions()
                : CyberwareConfig.BasicSlotExpansions()

    public static func BasicSlotExpansions() -> array<ExpansionArea> = [
        ExpansionArea.Create(gamedataEquipmentArea.SystemReplacementCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Milestone_3, 3)
        ])
    ];

    public static func ExtendedSlotExpansions() -> array<ExpansionArea> = [
        ExpansionArea.Create(gamedataEquipmentArea.SystemReplacementCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Milestone_3, 3),
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Master_Perk_3, 1)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.FrontalCortexCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Intelligence_Central_Milestone_3, 1),
            ExpansionSlot.Create(gamedataNewPerkType.Intelligence_Central_Milestone_3, 2)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.CardiovascularSystemCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Body_Central_Perk_1_4, 1)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.NervousSystemCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Milestone_3, 2)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.IntegumentarySystemCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Milestone_3, 1),
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Perk_3_3, 1)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.ArmsCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Perk_3_2, 1)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.HandsCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Tech_Central_Perk_3_2, 1)
        ]),
        ExpansionArea.Create(gamedataEquipmentArea.LegsCW, [
            ExpansionSlot.Create(gamedataNewPerkType.Reflexes_Central_Perk_1_3, 1)
        ])
    ];

    public static func Attachments() -> array<AttachmentSlot> = [
        AttachmentSlot.Create(n"CyberwareSlots.Berserk", n"Berserk"),
        AttachmentSlot.Create(n"CyberwareSlots.BoostedTendons", n"BoostedTendons"),
        AttachmentSlot.Create(n"CyberwareSlots.CapacityBooster", n"CapacityBooster"),
        AttachmentSlot.Create(n"CyberwareSlots.CatPaws", n"CatPaws"),
        AttachmentSlot.Create(n"CyberwareSlots.JenkinsTendons", n"JenkinsTendons"),
        AttachmentSlot.Create(n"CyberwareSlots.PowerGrip", n"PowerGrip"),
        AttachmentSlot.Create(n"CyberwareSlots.ReinforcedMuscles", n"ReinforcedMuscles"),
        AttachmentSlot.Create(n"CyberwareSlots.Sandevistan", n"Sandevistan"),
        AttachmentSlot.Create(n"CyberwareSlots.SmartLink", n"SmartLink")
    ];

    public static func Remappings() -> array<CyberwareRemapping> = [
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsBareBase", n"KiroshiOpticsBare"),
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsSensorBase", n"KiroshiOpticsSensor"),
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsHunterBase", n"KiroshiOpticsSensor"),
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsWallhackBase", n"KiroshiOpticsSensor"),
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsCombinedBase", n"KiroshiOpticsSensor"),
        CyberwareRemapping.Create(t"Items.AdvancedKiroshiOpticsPiercingBase", n"KiroshiOpticsPiercing"),
        CyberwareRemapping.Create(t"Items.Iconic_AdvancedKiroshiOpticsBareBase", n"KiroshiOpticsCrit")
    ];
}
