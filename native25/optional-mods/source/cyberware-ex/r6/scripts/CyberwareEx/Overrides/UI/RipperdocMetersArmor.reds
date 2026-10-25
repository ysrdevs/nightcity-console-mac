import CyberwareEx.*

@wrapMethod(RipperdocMetersArmor)
protected cb func OnInitialize() -> Bool {
    wrappedMethod();

    if IsExtendedMode() || IsOverrideMode() || IsCustomMode() {
        let root = this.GetRootWidget();

        let margin = root.GetMargin();
        margin.right = 370;
        root.SetMargin(margin);
    }
}

@wrapMethod(RipperdocMetersArmor)
protected cb func OnIntroAnimationFinished_METER(proxy: ref<inkAnimProxy>) -> Bool {
    wrappedMethod(proxy);

    if IsExtendedMode() || IsOverrideMode() || IsCustomMode() {
        let root = this.GetRootWidget();
        let parent = root.parentWidget as inkCompoundWidget;
        let wrapper = parent.GetWidget(n"wrapper") as inkCompoundWidget;

        let oldIndex = ArrayFindFirst(parent.children.children, root);
        let newIndex = ArrayFindFirst(wrapper.children.children, wrapper.GetWidget(n"paperDollWrapper")) + 1;
        root.Reparent(wrapper, newIndex);

        let dummy = new inkCanvas();
        parent.AddChildWidget(dummy);
        parent.ReorderChild(dummy, oldIndex);
    }
}
