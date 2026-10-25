module CyberwareEx

public struct OverrideArea {
    public let areaType: gamedataEquipmentArea;
    public let defaultSlots: Int32;
    public let maxSlots: Int32;

    public static func None() -> OverrideArea = OverrideArea(gamedataEquipmentArea.Invalid, 0, 0)
    public static func IsValid(slot: OverrideArea) -> Bool = NotEquals(slot.areaType, gamedataEquipmentArea.Invalid)
    
    public static func Create(areaType: gamedataEquipmentArea, maxSlots: Int32) -> OverrideArea =
        OverrideArea(areaType, 0, maxSlots)
}

public abstract class OverrideConfig {
    public static func SlotOverrides() -> array<OverrideArea> =
        IsCustomMode()
            ? GetCustomSlotOverrides()
            : OverrideConfig.DefaultSlotOverrides()

    public static func UpgradePrice() -> Int32 =
        IsCustomMode()
            ? GetCustomUpgradePrice()
            : OverrideConfig.DefaultUpgradePrice()

    public static func ResetPrice() -> Int32 =
        IsCustomMode()
            ? GetCustomResetPrice()
            : OverrideConfig.DefaultResetPrice()

    public static func DefaultSlotOverrides() -> array<OverrideArea> = [
        OverrideArea.Create(gamedataEquipmentArea.ArmsCW, 4),
        OverrideArea.Create(gamedataEquipmentArea.CardiovascularSystemCW, 6),
        OverrideArea.Create(gamedataEquipmentArea.EyesCW, 5),
        OverrideArea.Create(gamedataEquipmentArea.FrontalCortexCW, 6),
        OverrideArea.Create(gamedataEquipmentArea.HandsCW, 4),
        OverrideArea.Create(gamedataEquipmentArea.IntegumentarySystemCW, 6),
        OverrideArea.Create(gamedataEquipmentArea.LegsCW, 4),
        OverrideArea.Create(gamedataEquipmentArea.MusculoskeletalSystemCW, 6),
        OverrideArea.Create(gamedataEquipmentArea.NervousSystemCW, 6),
        OverrideArea.Create(gamedataEquipmentArea.SystemReplacementCW, 4)
    ];

     public static func DefaultUpgradePrice() -> Int32 = 10000
     public static func DefaultResetPrice() -> Int32 = 5000
}
