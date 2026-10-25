import CyberwareEx.*

@addField(RipperdocPerkTooltipData)
public let equipArea: gamedataEquipmentArea;

@addField(RipperdocPerkTooltipData)
public let slotIndex: Int32;

@wrapMethod(RipperdocPerkTooltip)
public func SetData(tooltipData: ref<ATooltipData>) {
    let perkTooltipData = tooltipData as RipperdocPerkTooltipData;
    let perkRecord = CyberwareHelper.GetRequiredPerkRecord(perkTooltipData.equipArea, perkTooltipData.slotIndex);
    if IsDefined(perkRecord) {
        let requiredLevel = CyberwareHelper.GetRequiredPerkLevel(perkTooltipData.equipArea, perkTooltipData.slotIndex);
        let maxLevel = CyberwareHelper.GetRequiredPerkMaxLevel(perkTooltipData.equipArea, perkTooltipData.slotIndex);
        let requirementLabel = GetLocalizedText(perkRecord.Loc_name_key());
        if maxLevel > 1 {
            requirementLabel += s"\n(\(GetLocalizedItemNameByCName(n"Gameplay-RPG-Skills-LevelName")) \(requiredLevel))";
        }
        inkTextRef.SetText(this.m_perkName, requirementLabel);
        inkImageRef.SetTexturePart(this.m_perkIcon, perkRecord.PerkIcon().AtlasPartName());
    } else {
        wrappedMethod(tooltipData);
    }
}
