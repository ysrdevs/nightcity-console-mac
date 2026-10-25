import CyberwareEx.*

@wrapMethod(ItemDisplayUtils)
public final static func SpawnCommonSlotAsync(logicController: ref<inkLogicController>, parent: inkWidgetRef,
                                              slotName: CName, opt callBack: CName, opt userData: ref<IScriptable>) {
    let slotUserData = userData as SlotUserData;
    if IsDefined(slotUserData) && slotUserData.isLocked {
        slotUserData.isPerkRequired = CyberwareHelper.IsPerkRequired(slotUserData.area, slotUserData.index);
    }
    wrappedMethod(logicController, parent, slotName, callBack, userData);
}
