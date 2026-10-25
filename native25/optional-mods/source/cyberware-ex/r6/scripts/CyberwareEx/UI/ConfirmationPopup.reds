module CyberwareEx

public enum OverrideAction {
    Upgrade = 1,
    Reset = 2
}

public class OverrideConfirmationPopup {
    public static func Show(controller: ref<worlduiIGameController>, action: OverrideAction, slotState: ref<OverrideState>) -> ref<inkGameNotificationToken> {
        let title = OverrideConfirmationPopup.GetTitle(action);

        let areaLabel = OverrideConfirmationPopup.GetAreaLabel();
        let areaName = OverrideConfirmationPopup.GetAreaName(slotState);

        let slotLabel = OverrideConfirmationPopup.GetSlotLabel();
        let initialSlots = OverrideConfirmationPopup.GetInitialSlots(action, slotState);
        let finalSlots = OverrideConfirmationPopup.GetFinalSlots(action, slotState);

        let priceLabel = OverrideConfirmationPopup.GetPriceLabel();
        let actionPrice = OverrideConfirmationPopup.GetActionPrice(action);

        let message = s"\(areaLabel): \(areaName)\n"
            + s"\(slotLabel): \(initialSlots) > \(finalSlots)\n"
            + s"\(priceLabel): \(actionPrice)";

        return GenericMessageNotification.Show(controller, EnumInt(slotState.areaType), title, message, GenericMessageNotificationType.ConfirmCancel);
    }

    public static func IsConfirmed(data: ref<inkGameNotificationData>) -> Bool {
        let popupData = data as GenericMessageNotificationCloseData;
        return Equals(popupData.result, GenericMessageNotificationResult.Confirm);
    }

    public static func GetAreaType(data: ref<inkGameNotificationData>) -> gamedataEquipmentArea {
        let popupData = data as GenericMessageNotificationCloseData;
        return IntEnum<gamedataEquipmentArea>(popupData.identifier);
    }

    private static func GetTitle(action: OverrideAction) -> String {
        return s"\(OverrideConfirmationPopup.GetActionLabel(action)) \(OverrideConfirmationPopup.GetAreaLabel())";
    }

    private static func GetActionLabel(action: OverrideAction) -> String {
        return Equals(action, OverrideAction.Upgrade)
            ? GetLocalizedTextByKey(n"UI-Crafting-Upgrade")
            : GetLocalizedTextByKey(n"UI-ResourceExports-Reset");
    }

    // private static func GetActionText(action: OverrideAction) -> String {
    //     return s"\(OverrideConfirmationPopup.GetActionLabel(action)) \(GetLocalizedText("LocKey#36278"))";
    // }

    private static func GetInitialSlots(action: OverrideAction, slotState: ref<OverrideState>) -> Int32 {
        return slotState.currentSlots;
    }

    private static func GetFinalSlots(action: OverrideAction, slotState: ref<OverrideState>) -> Int32 {
        return Equals(action, OverrideAction.Upgrade) ? slotState.currentSlots + 1 : slotState.defaultSlots;
    }

    private static func GetActionPrice(action: OverrideAction) -> Int32 {
        return Equals(action, OverrideAction.Upgrade) ? OverrideConfig.UpgradePrice() : OverrideConfig.ResetPrice();
    }

    private static func GetAreaName(slotState: ref<OverrideState>) -> String {
        let name = EnumValueToString("gamedataEquipmentArea", Cast<Int64>(EnumInt(slotState.areaType)));
        let record = TweakDBInterface.GetEquipmentAreaRecord(TDBID.Create("EquipmentArea." + name));
        let result = record.LocalizedName();
        return NotEquals(result, "") ? GetLocalizedText(result) : name;
    }

    private static func GetAreaLabel() -> String = GetLocalizedText("UI-ResourceExports-Cyberware")
    private static func GetSlotLabel() -> String = GetLocalizedText("LocKey#53485")
    private static func GetPriceLabel() -> String = GetLocalizedText("UI-ResourceExports-Price")
    // private static func GetCurrencyLabel() -> String = GetLocalizedText("LocKey#13363")
}
