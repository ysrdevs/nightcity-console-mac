import CyberwareEx.*

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    wrappedMethod();

    if this.IsControlledByLocalPeer() || IsHost() {
        this.RegisterInputListener(this, n"ToggleSprint");
    }
}

@wrapMethod(PlayerPuppet)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
    if this.PlayerLastUsedPad() && Equals(ListenerAction.GetName(action), n"ToggleSprint")
        && Equals(ListenerAction.GetType(action), gameinputActionType.BUTTON_RELEASED) {
        let psmBlackboard = this.GetPlayerStateMachineBlackboard();
        let isFocusMode = Equals(IntEnum<gamePSMVision>(psmBlackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Vision)), gamePSMVision.Focus);
        if isFocusMode {
            if QuickHackableHelper.TryToCycleOverclockedState(this) {
                let dpadAction = new DPADActionPerformed();
                dpadAction.action = EHotkey.LBRB;
                dpadAction.state = EUIActionState.COMPLETED;
                dpadAction.successful = true;

                GameInstance.GetUISystem(this.GetGame()).QueueEvent(dpadAction);
            }
        }
    } else {
        wrappedMethod(action, consumer);
    }
}

@replaceMethod(PlayerPuppet)
private final func ActivateIconicCyberware() {
    let equipmentData = EquipmentSystem.GetData(this);
    let characterData = PlayerDevelopmentSystem.GetData(this);

    let hasBerserk = equipmentData.HasTaggedItem(gamedataEquipmentArea.SystemReplacementCW, n"Berserk");
    let hasSandevistan = equipmentData.HasTaggedItem(gamedataEquipmentArea.SystemReplacementCW, n"Sandevistan");
    let hasOverclock = equipmentData.HasTaggedItem(gamedataEquipmentArea.SystemReplacementCW, n"Cyberdeck")
        && characterData.IsNewPerkBought(gamedataNewPerkType.Intelligence_Central_Milestone_3) == 3;

    let numberOfAbilities = (hasBerserk ? 1 : 0) + (hasSandevistan ? 1 : 0) + (hasOverclock ? 1 : 0);
    if numberOfAbilities == 0 {
        return;
    }

    let isOnlyOneAbility = numberOfAbilities == 1;
    let isCombinedAbilityMode = IsCombinedAbilityMode();

    let statsSystem = GameInstance.GetStatsSystem(this.GetGame());
    let playerStatsId = Cast<StatsObjectID>(this.GetEntityID());
    let canUseBerserk = statsSystem.GetStatBoolValue(playerStatsId, gamedataStatType.HasBerserk);
    let canUseSandevistan = statsSystem.GetStatBoolValue(playerStatsId, gamedataStatType.HasSandevistan);

    let psmBlackboard = this.GetPlayerStateMachineBlackboard();
    let meleeWeaponState = IntEnum<gamePSMMeleeWeapon>(psmBlackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.MeleeWeapon));

    let isFocusMode = Equals(IntEnum<gamePSMVision>(psmBlackboard.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Vision)), gamePSMVision.Focus);
    let isBlocking = Equals(meleeWeaponState, gamePSMMeleeWeapon.Block) || Equals(meleeWeaponState, gamePSMMeleeWeapon.BlockAttack)
        || Equals(meleeWeaponState, gamePSMMeleeWeapon.Deflect) || Equals(meleeWeaponState, gamePSMMeleeWeapon.DeflectAttack);
    let isInVehicle = psmBlackboard.GetBool(GetAllBlackboardDefs().PlayerStateMachine.MountedToVehicle);

    let attempted = false;
    let activated = false;

    if hasOverclock && (isOnlyOneAbility || isFocusMode || isCombinedAbilityMode) {
        attempted = true;
        if QuickHackableHelper.TryToCycleOverclockedState(this) {
            activated = true;
        }
    }

    if hasBerserk && !isFocusMode && (isOnlyOneAbility || ((isBlocking || !hasSandevistan)) || isCombinedAbilityMode) {
        if canUseBerserk && !isInVehicle {
            let berserkItem = equipmentData.GetTaggedItem(gamedataEquipmentArea.SystemReplacementCW, n"Berserk");

            attempted = true;
            if ItemActionsHelper.UseItem(this, berserkItem) {
                activated = true;
            }
        }
    }

    if hasSandevistan && !isFocusMode && (isOnlyOneAbility || ((!isBlocking || !hasBerserk)) || isCombinedAbilityMode) {
        if canUseSandevistan && TimeDilationHelper.CanUseTimeDilation(this) {
            let sandevistanItem = equipmentData.GetTaggedItem(gamedataEquipmentArea.SystemReplacementCW, n"Sandevistan");

            attempted = true;
            if ItemActionsHelper.UseItem(this, sandevistanItem) {
                activated = true;
            }
        }
    }

    if attempted {
        if activated {
            this.IconicCyberwareActivated();
        } else {
            let audioEvent = new SoundPlayEvent();
            audioEvent.soundName = n"ui_grenade_empty";

            this.QueueEvent(audioEvent);
        }

        let dpadAction = new DPADActionPerformed();
        dpadAction.action = EHotkey.LBRB;
        dpadAction.state = EUIActionState.COMPLETED;
        dpadAction.successful = activated;

        GameInstance.GetUISystem(this.GetGame()).QueueEvent(dpadAction);
    }
}

// Overrides the time dilation cleanup routine so that it can handle several active effects at the same time,
// Sandevistan + Focus Mode in particular.
@wrapMethod(PlayerPuppet)
protected cb func OnCleanUpTimeDilationEvent(evt: ref<CleanUpTimeDilationEvent>) -> Bool {
    let timeSystem = GameInstance.GetTimeSystem(this.GetGame());
    if !timeSystem.IsTimeDilationActive() {
        wrappedMethod(evt);
    }
}
