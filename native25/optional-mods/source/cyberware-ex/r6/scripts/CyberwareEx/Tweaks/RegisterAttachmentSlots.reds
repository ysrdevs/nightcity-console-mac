module CyberwareEx

class RegisterAttachmentSlots extends ScriptableTweak {
    protected func OnApply() {
        let attachmentSlots = CyberwareConfig.Attachments();

        for attachmentSlot in attachmentSlots {
            TweakDBManager.CreateRecord(attachmentSlot.slotID, n"AttachmentSlot_Record");
            TweakDBManager.RegisterName(attachmentSlot.slotName);
        }

        let playerEntityTemplates = [
            r"base\\characters\\entities\\player\\player_wa_fpp.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_cutscene.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_cutscene_no_impostor.ent",
            r"base\\characters\\entities\\player\\player_wa_tpp_reflexion.ent",
            r"base\\characters\\entities\\player\\player_ma_fpp.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_cutscene.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_cutscene_no_impostor.ent",
            r"base\\characters\\entities\\player\\player_ma_tpp_reflexion.ent"
        ];

        let playerDisplayName = GetLocalizedTextByKey(TweakDBInterface.GetLocKeyDefault(t"Character.Player_Puppet_Base.displayName"));

        for record in TweakDBInterface.GetRecords(n"Character_Record") {
            let character = record as Character_Record;
            if ArrayContains(playerEntityTemplates, character.EntityTemplatePath()) || Equals(GetLocalizedTextByKey(character.DisplayName()), playerDisplayName) {
                let characterSlots = TweakDBInterface.GetForeignKeyArray(character.GetID() + t".attachmentSlots");
                if ArrayContains(characterSlots, t"AttachmentSlots.SystemReplacementCW") {
                    for attachmentSlot in attachmentSlots {
                        if !ArrayContains(characterSlots, attachmentSlot.slotID) {
                            ArrayPush(characterSlots, attachmentSlot.slotID);
                        }
                    }

                    TweakDBManager.SetFlat(character.GetID() + t".attachmentSlots", characterSlots);
                    TweakDBManager.UpdateRecord(character.GetID());
                }
            }
        }
    }
}
