@wrapMethod(QuickhacksListGameController)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    if !this.m_isUILocked && !this.GetPlayerControlledObject().GetHudManager().IsHackingMinigameActive() {
        if ListenerAction.IsButtonJustReleased(action) && ListenerAction.IsAction(action, n"context_help") {
            if QuickHackableHelper.TryToCycleOverclockedState(this.GetPlayerControlledObject()) {
                let dpadAction = new DPADActionPerformed();
                dpadAction.action = EHotkey.LBRB;
                dpadAction.state = EUIActionState.COMPLETED;
                dpadAction.successful = true;

                GameInstance.GetUISystem(this.GetPlayerControlledObject().GetGame()).QueueEvent(dpadAction);
            }

            return false;
        }
    }

    return wrappedMethod(action, consumer);
}

@replaceMethod(QuickhacksListGameController)
private final func ToggleTutorialOverlay() {
    //
}
