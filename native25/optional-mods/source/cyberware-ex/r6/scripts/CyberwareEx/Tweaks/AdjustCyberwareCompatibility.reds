module CyberwareEx

class AdjustCyberwareCompatibility extends ScriptableTweak {
    protected func OnApply() {
        // Enable different cyberware combinations
        let attachmentSlots = CyberwareConfig.Attachments();
        let cyberwareRemappings = CyberwareConfig.Remappings();
        for record in TweakDBInterface.GetRecords(n"Item_Record") {
            let cyberwareTypeFlat = TweakDBInterface.GetFlat(record.GetID() + t".cyberwareType");
            if IsDefined(cyberwareTypeFlat) {
                let cyberwareType = FromVariant<CName>(cyberwareTypeFlat);
                let placementSlots = TweakDBInterface.GetForeignKeyArray(record.GetID() + t".placementSlots");
                if ArraySize(placementSlots) > 0 {
                    if Equals(cyberwareType, n"IconicJenkinsTendons") {
                        cyberwareType = n"JenkinsTendons";
                        TweakDBManager.SetFlat(record.GetID() + t".cyberwareType", cyberwareType);
                    }
                    for attachmentSlot in attachmentSlots {
                        if Equals(cyberwareType, attachmentSlot.cyberwareType) {
                            TweakDBManager.SetFlat(record.GetID() + t".placementSlots", [attachmentSlot.slotID]);
                            TweakDBManager.UpdateRecord(record.GetID());
                            break;
                        }
                    }
                } else {
                    for cyberwareRemapping in cyberwareRemappings {
                        let displayName = TweakDBInterface.GetLocKeyDefault(record.GetID() + t".displayName");
                        if Equals(displayName, cyberwareRemapping.displayName) {
                            TweakDBManager.SetFlat(record.GetID() + t".cyberwareType", cyberwareRemapping.cyberwareType);
                            break;
                        }
                    }
                }
            }
        }

        // Fix Sandevistan + Berserk time dilation conflict
        TweakDBManager.SetFlat(t"BaseStatusEffect.BerserkTimeDilationEffector.effectorClassName", n"");
        TweakDBManager.UpdateRecord(t"BaseStatusEffect.BerserkTimeDilationEffector");

        // Allow double jump after charged jump
        let chargeJumpTransitions = TweakDBInterface.GetStringArray(t"playerStateMachineLocomotion.chargeJump.transitionTo");
        let chargeJumpConditions = TweakDBInterface.GetStringArray(t"playerStateMachineLocomotion.chargeJump.transitionCondition");
        if !ArrayContains(chargeJumpTransitions, "doubleJump") {
            ArrayPush(chargeJumpTransitions, "doubleJump");
            ArrayPush(chargeJumpConditions, "");
            TweakDBManager.SetFlat(t"playerStateMachineLocomotion.chargeJump.transitionTo", chargeJumpTransitions);
            TweakDBManager.SetFlat(t"playerStateMachineLocomotion.chargeJump.transitionCondition", chargeJumpConditions);
        }
    }
}
