// Allows Projectile Launcher System to be chanrged when multiple cyberarms are equipped.
@wrapMethod(EquippedDecisions)
protected final const func ToUnequipCycle(stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    if this.IsLeftHandLogic(this.stateMachineInstanceData) {
        let minActiveState = EnumInt(gamePSMLeftHandCyberware.Equipped);
        let maxActiveState = EnumInt(gamePSMLeftHandCyberware.CatchAction);
        let leftHandCyberwareState = scriptInterface.localBlackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.LeftHandCyberware);
        if leftHandCyberwareState >= minActiveState && leftHandCyberwareState <= maxActiveState {
            return false;
        }
    }

    return wrappedMethod(stateContext, scriptInterface);
}
