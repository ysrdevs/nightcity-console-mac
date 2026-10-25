module CyberwareEx

public class ConflictsPopup {
    public static func Show(controller: ref<inkGameController>) -> ref<inkGameNotificationToken> {
        let game = controller.GetPlayerControlledObject().GetGame();
        let conflicts: array<String>;
        CompatibilityManager.CheckConflicts(game, conflicts);

        let conflictStr: String;
        for conflict in conflicts {
            conflictStr += "- " + conflict + "\n";
        }
        
        let params = new inkTextParams();
        params.AddString("conflicts", conflictStr);

        return GenericMessageNotification.Show(
            controller, 
            GetLocalizedText("LocKey#11447"), 
            GetLocalizedTextByKey(n"UI-CyberwareEx-NotificationConflicts"), 
            params,
            GenericMessageNotificationType.OK
        );
    }
}
