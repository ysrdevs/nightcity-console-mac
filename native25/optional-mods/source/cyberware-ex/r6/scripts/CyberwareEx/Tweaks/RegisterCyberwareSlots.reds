module CyberwareEx

class RegisterCyberwareSlots extends ScriptableTweak {
    protected func OnApply() {
        if !IsDefined(TweakDBInterface.GetRecord(t"EquipmentArea.SkeletonEquipSlot")) {
            TweakDBManager.CloneRecord(n"EquipmentArea.SkeletonEquipSlot", t"EquipmentArea.SimpleEquipSlot");
        }

        if IsOverrideMode() {
            return;
        }

        for expansion in CyberwareConfig.SlotExpansions() {
            let equipmentAreaID = TDBID.Create(s"EquipmentArea.\(expansion.equipmentArea)");
            let equipmentAreaSlots = TweakDBInterface.GetForeignKeyArray(equipmentAreaID + t".equipSlots");

            let defaultNumSlots = TweakDBInterface.GetIntDefault(equipmentAreaID + t".defaultNumSlots");
            if defaultNumSlots == 0 {
                defaultNumSlots = ArraySize(equipmentAreaSlots);
            } else {
                ArrayResize(equipmentAreaSlots, defaultNumSlots);
            }

            for extraSlot in expansion.extraSlots {
                let extraSlotIndex = ArraySize(equipmentAreaSlots);
                ArrayPush(equipmentAreaSlots,
                    CyberwareHelper.CreateEquipSlotRecord(
                        expansion.equipmentArea,
                        extraSlotIndex,
                        extraSlot.requiredPerk,
                        extraSlot.requiredLevel));
            }

            TweakDBManager.SetFlat(equipmentAreaID + t".defaultNumSlots", defaultNumSlots);
            TweakDBManager.SetFlat(equipmentAreaID + t".equipSlots", equipmentAreaSlots);
            TweakDBManager.UpdateRecord(equipmentAreaID);
        }
    }
}
