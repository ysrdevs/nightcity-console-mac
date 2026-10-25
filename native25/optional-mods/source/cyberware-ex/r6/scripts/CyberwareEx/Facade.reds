import CyberwareEx.*

public abstract class CyberwareEx {
    public static func Version() -> String = "1.5.6"

    public static func ResetSlot(game: GameInstance, areaType: gamedataEquipmentArea) {
        let player = GetPlayer(game);
        let overrideManager = new OverrideManager();
        overrideManager.Initialize(EquipmentSystem.GetData(player));
        overrideManager.ResetSlot(areaType, true);
    }

    public static func ResetAllSlots(game: GameInstance) {
        let player = GetPlayer(game);
        let overrideManager = new OverrideManager();
        overrideManager.Initialize(EquipmentSystem.GetData(player));
        for override in OverrideConfig.SlotOverrides() {
            overrideManager.ResetSlot(override.areaType, true);
        }
    }

    public static func UpgradeSlot(game: GameInstance, areaType: gamedataEquipmentArea, opt count: Int32) {
        if IsOverrideMode() {
            let player = GetPlayer(game);
            let overrideManager = new OverrideManager();
            overrideManager.Initialize(EquipmentSystem.GetData(player));
            if count == 0 {
                count = 1;
            }
            while (count > 0) {
                overrideManager.UpgradeSlot(areaType, true);
                count -= 1;
            }
        }
    }

    public static func UpgradeAllSlotsToMax(game: GameInstance) {
        if IsOverrideMode() {
            let player = GetPlayer(game);
            let overrideManager = new OverrideManager();
            overrideManager.Initialize(EquipmentSystem.GetData(player));
            for override in OverrideConfig.SlotOverrides() {
                while (overrideManager.UpgradeSlot(override.areaType, true)) {}
            }
        }
    }
}
