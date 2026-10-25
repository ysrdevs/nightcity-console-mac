module CyberwareEx

public abstract class CompatibilityManager {
    public static func RequiredTweakXL() -> String = "1.11.3";
    public static func RequiredCodeware() -> String = "1.20.1";

    public static func CheckRequirements() -> Bool {
        return Codeware.Require(CompatibilityManager.RequiredCodeware())
            && TweakXL.Require(CompatibilityManager.RequiredTweakXL());
    }

    public static func CheckConflicts(game: GameInstance, out conflicts: array<String>) -> Bool {
        let itemController = new InventoryItemDisplayController();
        itemController.SetLocked(true, true);
        if !itemController.m_isLocked {
            if itemController.m_visibleWhenLocked {
                ArrayPush(conflicts, "No Special Outfit Lock");
            } else {
                ArrayPush(conflicts, "Never Lock Outfits");
            }
        }

        return ArraySize(conflicts) == 0;
    }

    public static func CheckConflicts(game: GameInstance) -> Bool {
        let conflicts: array<String>;
        return CompatibilityManager.CheckConflicts(game, conflicts);
    }

    public static func IsUserNotified() -> Bool {
        return TweakDBInterface.GetBool(t"CyberwareEx.isUserNotified", false);
    }

    public static func MarkAsNotified() {
        TweakDBManager.SetFlat(t"CyberwareEx.isUserNotified", true);
    }
}
