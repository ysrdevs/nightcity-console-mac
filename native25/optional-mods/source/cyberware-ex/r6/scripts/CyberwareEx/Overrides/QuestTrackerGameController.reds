import CyberwareEx.{CompatibilityManager, ConflictsPopup, RequirementsPopup}

@addField(QuestTrackerGameController)
private let m_cyberwareExPopup: ref<inkGameNotificationToken>;

@wrapMethod(QuestTrackerGameController)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    if !CompatibilityManager.IsUserNotified() {
        if !CompatibilityManager.CheckRequirements() {
            this.m_cyberwareExPopup = RequirementsPopup.Show(this);
            this.m_cyberwareExPopup.RegisterListener(this, n"OnCyberwareExPopupClose");
        } else {
            if !CompatibilityManager.CheckConflicts(this.m_player.GetGame()) {
                this.m_cyberwareExPopup = ConflictsPopup.Show(this);
                this.m_cyberwareExPopup.RegisterListener(this, n"OnCyberwareExPopupClose");
            }
        }
        CompatibilityManager.MarkAsNotified();
    }
}

@addMethod(QuestTrackerGameController)
protected cb func OnCyberwareExPopupClose(data: ref<inkGameNotificationData>) {
    this.m_cyberwareExPopup = null;
}
