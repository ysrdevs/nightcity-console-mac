@wrapMethod(PlayerDevelopmentData)
private final func HandleAddingPerkLevel(i: Int32, j: Int32) {
    if Equals(this.m_attributesData[i].unlockedPerks[j].type, gamedataNewPerkType.Tech_Central_Milestone_3) && this.m_attributesData[i].unlockedPerks[j].currLevel == 3 {
        EquipmentSystem.GetData(this.m_owner).ApplyAreaPowerUps(gamedataEquipmentArea.MusculoskeletalSystemCW);
    }
}
