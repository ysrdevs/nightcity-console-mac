@replaceMethod(DoubleJumpDecisions)
protected const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
    let jumpPressedFlag = stateContext.GetConditionBool(n"JumpPressed");
    if !jumpPressedFlag && !this.m_jumpPressed {
        this.EnableOnEnterCondition(false);
    }
    if !scriptInterface.HasStatFlag(gamedataStatType.HasDoubleJump) {
        return false;
    }
    if StatusEffectSystem.ObjectHasStatusEffect(scriptInterface.executionOwner, t"BaseStatusEffect.HealFood3") {
        return false;
    }
    //if scriptInterface.HasStatFlag(gamedataStatType.HasChargeJump) || scriptInterface.HasStatFlag(gamedataStatType.HasAirHover) {
    //    return false;
    //}
    if this.IsCurrentFallSpeedTooFastToEnter(stateContext, scriptInterface) {
        return false;
    }
    if scriptInterface.localBlackboard.GetBool(GetAllBlackboardDefs().PlayerStateMachine.IsPlayerInsideMovingElevator) {
        return false;
    }
    let currentNumberOfJumps = stateContext.GetIntParameter(n"currentNumberOfJumps", true);
    if currentNumberOfJumps >= this.GetStaticIntParameterDefault("numberOfMultiJumps", 1) {
        return false;
    }
    if jumpPressedFlag || scriptInterface.IsActionJustPressed(n"Jump") {
        return true;
    }
    return false;
}
