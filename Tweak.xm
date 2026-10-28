/*
 *  AlipayFullscreenFix — 支付宝全屏黑边修复
 *
 *  移植自 QQFullscreenFix 2.0.1 (Author: QAQ)，逐条对齐其 Hook 点与判定条件。
 *
 *  问题成因：各类分屏/改比例的注入把 App 塞进非原生比例的容器里时，UIKit 侧
 *  仍有大量 window / 容器 view 沿用旧的（错误的）高度，而 [UIScreen mainScreen].bounds
 *  此时已经是正确的全屏尺寸，于是底部出现一条黑框。
 *
 *  修复思路：在多处布局入口把「宽度已是全屏宽、高度仍是旧值、且顶部对齐」的容器，
 *  重新对齐到 nativeBounds / scale 得到的真实全屏尺寸。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <substrate.h>

/* 调试开关：想看详细日志就改成 1 重新编译，日志前缀 [AlipayFullscreenFix] */
#ifndef AI_VERBOSE_LOG
#define AI_VERBOSE_LOG 0
#endif

#if AI_VERBOSE_LOG
#  define AILog(...) NSLog(@"[AlipayFullscreenFix] " __VA_ARGS__)
#else
#  define AILog(...) ((void)0)
#endif

#pragma mark - ══════════════ 可调区域 ══════════════

/* 参与修正时被跳过的类名关键字（与 QQ 版完全一致，16 个）*/
static NSString * const kIgnoreKeywords[] = {
    @"TabBar",      @"BarBackground", @"NavigationBar", @"Toolbar",
    @"StatusBar",   @"Keyboard",      @"InputSet",      @"Alert",
    @"PillView",    @"Indicator",     @"VisualEffect",  @"Backdrop",
    @"Blur",        @"TintView",      @"DimmingView",   @"GradientView"
};
static const NSUInteger kIgnoreKeywordCount =
    sizeof(kIgnoreKeywords) / sizeof(kIgnoreKeywords[0]);

/* 需要额外修正高度的系统窗口类关键字（键盘 / 输入相关）*/
static NSString * const kWindowKeywords[] = { @"TextEffects", @"Input", @"Keyboard" };
static const NSUInteger kWindowKeywordCount =
    sizeof(kWindowKeywords) / sizeof(kWindowKeywords[0]);

/*
 * 支付宝侧需要额外 hook 的容器类。
 * 找不到（objc_getClass 返回 NULL）会自动跳过，不会有任何副作用 —— 按需增删即可。
 */
static NSString * const kAppContainerClasses[] = {
    @"DTView",              // mPaaS 通用容器
    @"APRootView",
    @"APBaseView",
    @"APBorderView",
    @"MPBaseView",
    @"H5BaseWebView",
    @"NebulaWKWebView",
    @"APTabBar",
    @"NMUITabBar"
};
static const NSUInteger kAppContainerClassCount =
    sizeof(kAppContainerClasses) / sizeof(kAppContainerClasses[0]);

#pragma mark - ══════════════ 内部状态 ══════════════

static BOOL      gIsFixing   = NO;      // 防重入标记
static CGFloat   gStaleHeight = 0;      // 被覆盖前的「旧高度」
static UIWindow *gTargetWindow = nil;   // 当期正在修正的主窗口
static UIView   *gSavedRootView = nil;  // 已处理过的 rootView（避免递归误伤）
static CGFloat   gKeyboardEndY = 0;     // 键盘最终的 y

#pragma mark - ══════════════ 原始 IMP ══════════════

static void (*orig_UIWindow_setBounds)(UIWindow *, SEL, CGRect);
static void (*orig_UIView_setBounds)(UIView *, SEL, CGRect);
static void (*orig_UILayoutContainerView_layoutSubviews)(UIView *, SEL);
static void (*orig_UITransitionView_layoutSubviews)(UIView *, SEL);
static void (*orig_UITabBar_setBounds)(UIView *, SEL, CGRect);

/* 动态 hooked 的 App 私有类 */
typedef struct { Class cls; IMP origLayout; IMP origBounds; } AIExtraHook;
static AIExtraHook gExtraHooks[kAppContainerClassCount];

#pragma mark - ══════════════ 小工具 ══════════════

/* 真实全屏尺寸：nativeBounds / scale */
static CGRect AIFullscreenRect(void)
{
    UIScreen *screen = [UIScreen mainScreen];
    CGRect  nb    = screen.nativeBounds;
    CGFloat scale = screen.scale;
    if (scale <= 0) scale = 1.0;
    return CGRectMake(0, 0, nb.size.width / scale, nb.size.height / scale);
}

/* 当前是否处在「屏幕已经是全屏尺寸」的状态 —— 这是所有修正的开关 */
static BOOL AIScreenIsFullscreen(void)
{
    CGRect full = AIFullscreenRect();
    return CGRectEqualToRect([UIScreen mainScreen].bounds, full);
}

static BOOL AINameIsIgnored(NSString *name)
{
    for (NSUInteger i = 0; i < kIgnoreKeywordCount; i++) {
        if ([name containsString:kIgnoreKeywords[i]]) return YES;
    }
    return NO;
}

static BOOL AIClassIsIgnored(UIView *v)
{
    return AINameIsIgnored(NSStringFromClass([v class]));
}

static BOOL AINameIsHostWindow(NSString *name)
{
    for (NSUInteger i = 0; i < kWindowKeywordCount; i++) {
        if ([name containsString:kWindowKeywords[i]]) return YES;
    }
    return NO;
}

static inline void AIApplyRect(UIView *v, CGRect r)
{
    [v setBounds:r];
    [v setFrame:r];
}

#pragma mark - ══════════════ 核心判定 ══════════════

/*
 * 0x5fd0：候选主窗口的筛选条件。
 *   - 不能 hidden
 *   - 必须是 UIWindowLevelNormal
 *   - 类名不能含 Input / Keyboard
 *   - frame 宽度必须已经是全屏宽
 */
static BOOL AIWindowIsCandidate(UIWindow *w, CGRect full)
{
    if (!w || [w isHidden]) return NO;
    if ([w windowLevel] != UIWindowLevelNormal) return NO;

    NSString *name = NSStringFromClass([w class]);
    if ([name containsString:@"Input"] || [name containsString:@"Keyboard"]) return NO;

    CGRect f = [w frame];
    return fabs(f.size.width - full.size.width) <= 1.0;
}

/*
 * 0x6698：容器 view 是否需要被修正。
 *   - 向上最多 10 层找到宿主 UIWindow
 *   - 宿主窗口宽度已是全屏宽
 *   - 屏幕当前确实是全屏尺寸
 *   - 该 view 的 bounds 宽度已是全屏宽、高度仍不等于全屏高
 *   - 旧高度 > 100，且与新 bounds 高度相差 < 3
 *   - bounds.origin.y 接近 0
 *   - 类名不在忽略清单里，且不是 UIScrollView
 */
static BOOL AIViewNeedsFullscreenFix(UIView *v, CGRect bounds)
{
    if (!v) return NO;

    UIView *sup = [v superview];
    if (!sup) return NO;

    UIView *host = nil;
    for (NSInteger i = 0; i < 10; i++) {
        if ([sup isKindOfClass:[UIWindow class]]) { host = sup; break; }
        UIView *next = [sup superview];
        if (!next) return NO;
        sup = next;
    }
    if (!host) return NO;

    CGRect full = AIFullscreenRect();
    if (fabs([host frame].size.width - full.size.width) >= 1.0) return NO;
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return NO;
    if (fabs(bounds.size.width  - full.size.width ) >  1.0) return NO;
    if (fabs(bounds.size.height - full.size.height) <= 1.0) return NO;
    if (gStaleHeight <= 100.0) return NO;
    if (fabs(bounds.size.height - gStaleHeight) >= 3.0) return NO;
    if (fabs(bounds.origin.y) >= 1.0) return NO;
    if (AIClassIsIgnored(v)) return NO;
    if ([v isKindOfClass:[UIScrollView class]]) return NO;

    return YES;
}

/*
 * 通用子视图判定（0x5698 / 0x5980 里反复出现的那串判断）：
 *   宽度 == 参考宽度、高度 != 参考高度、且旧高度与之一致、顶部对齐、不在忽略清单、非 UIScrollView
 */
static BOOL AISubviewNeedsFix(UIView *sub, CGFloat refW, CGFloat refH)
{
    CGRect f = [sub frame];
    if (fabs(f.size.width  - refW) >= 1.0) return NO;   // 宽度得已经是全宽
    if (fabs(f.size.height - refH) <= 1.0) return NO;   // 高度还是旧值才需要处理
    if (gStaleHeight <= 100.0) return NO;               // 需要有可信的旧高度做参照
    if (fabs(f.size.height - gStaleHeight) >= 3.0) return NO;
    if (fabs(f.origin.y) >= 1.0) return NO;             // 顶部对齐
    if (AIClassIsIgnored(sub)) return NO;
    if ([sub isKindOfClass:[UIScrollView class]]) return NO;
    return YES;
}

#pragma mark - ══════════════ 修正流程 ══════════════

/* 前向声明（互相递归）*/
static void AIFixWindow(UIWindow *window);
static void AIFixViewRecursively(UIView *view, NSInteger depth, CGRect full);
static void AIFixAllWindows(void);
static void AIFixTextWindows(void);
static UIView *AIFindFirstResponder(UIView *v);
static void AICheckAndFix(void);

/* 0x5698：把某个窗口的内容收拾干净 */
static void AIFixWindow(UIWindow *window)
{
    if (!window) return;

    UIViewController *rvc = [window rootViewController];
    UIView *rootView = [rvc view];
    if (!rootView) return;

    CGRect winBounds = [window bounds];

    /* rootView 与窗口不一致时直接对齐 */
    if (!CGRectEqualToRect([rootView frame], winBounds)) {
        AIApplyRect(rootView, winBounds);
    }

    /* 残留的整体缩放会让坐标错位，复位 */
    if (!CGAffineTransformIsIdentity([rootView transform])) {
        [rootView setTransform:CGAffineTransformIdentity];
    }

    for (UIView *sub in [rootView subviews]) {
        if (!AISubviewNeedsFix(sub, winBounds.size.width, winBounds.size.height)) continue;
        AIApplyRect(sub, CGRectMake(0, 0, winBounds.size.width, winBounds.size.height));
    }

    [window layoutIfNeeded];
}

/* 0x5980：递归修正视图树，最大深度 7 */
static void AIFixViewRecursively(UIView *view, NSInteger depth, CGRect full)
{
    if (!view) return;
    if (depth >= 7) return;
    if (view == gSavedRootView) return;

    if (!gIsFixing) {
        CGRect b = [view bounds];
        if (fabs(b.size.width  - full.size.width ) <  1.0 &&
            fabs(b.size.height - full.size.height) >  1.0 &&
            gStaleHeight > 100.0                          &&
            fabs(b.size.height - gStaleHeight)    <  3.0  &&
            fabs([view frame].origin.y)           <  1.0  &&
            !AIClassIsIgnored(view)                       &&
            ![view isKindOfClass:[UIScrollView class]])
        {
            gIsFixing = YES;
            gStaleHeight = b.size.height;
            AILog(@"fix view %@ h=%.1f -> %.1f", NSStringFromClass([view class]),
                  b.size.height, full.size.height);
            AIApplyRect(view, full);
            gIsFixing = NO;
        }
    }

    for (UIView *sub in [view subviews]) {
        AIFixViewRecursively(sub, depth + 1, full);
    }
}

/* 0x4374：扫描所有窗口，找出需要修正的那个并修掉 */
static void AIFixAllWindows(void)
{
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;

    CGRect full = AIFullscreenRect();
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return;

    UIWindow *candidate = nil;
    for (UIWindow *w in [app windows]) {
        if (AIWindowIsCandidate(w, full)) { candidate = w; break; }
    }
    if (!candidate) return;

    gTargetWindow = candidate;
    [gTargetWindow setBounds:full];

    UIViewController *rvc = [gTargetWindow rootViewController];
    gSavedRootView = [rvc view];

    AIFixWindow(gTargetWindow);

    /* rootView 也要二次确认 */
    UIViewController *rvc2 = [gTargetWindow rootViewController];
    UIView *rv2 = [rvc2 view];
    if (rv2) {
        if (!CGRectEqualToRect([rv2 frame], [gTargetWindow bounds])) {
            [gTargetWindow setBounds:full];
            AIFixWindow(gTargetWindow);
        }
        AIFixViewRecursively(rv2, 0, full);
    }

    AIFixTextWindows();
}

/* 0x5bcc：键盘 / 输入相关窗口的高度夹值 */
static void AIFixTextWindows(void)
{
    CGRect full = AIFullscreenRect();
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return;

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;

    for (UIWindow *w in [app windows]) {
        NSString *name = NSStringFromClass([w class]);
        if (!AINameIsHostWindow(name)) continue;

        CGRect f = [w frame];
        if (f.size.height > 50.0 && fabs(f.size.height - full.size.height) > 1.0) {
            [w setBounds:CGRectMake(f.origin.x, f.origin.y, f.size.width, full.size.height)];
        }
    }
}

/* 0x60a8：递归找到第一响应者所在的 view */
static UIView *AIFindFirstResponder(UIView *v)
{
    if (!v) return nil;
    if ([v isFirstResponder]) return v;
    for (UIView *sub in [v subviews]) {
        UIView *hit = AIFindFirstResponder(sub);
        if (hit) return hit;
    }
    return nil;
}

#pragma mark - ══════════════ 主检查入口 ══════════════

/* 0x4148：DidBecomeActive / 每 0.5s 跑一次的总入口 */
static void AICheckAndFix(void)
{
    CGRect full = AIFullscreenRect();

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return;

    AIFixAllWindows();

    UIWindow *w = gTargetWindow;
    if (!w) return;

    /* 窗口 frame 还不是全屏尺寸 → 直接按全屏尺寸刷一遍 */
    if (!CGRectEqualToRect([w frame], full)) {
        [w setBounds:full];
        AIFixWindow(w);
    }

    UIViewController *rvc = [w rootViewController];
    UIView *rv = [rvc view];
    if (rv) {
        if (!CGRectEqualToRect([rv frame], [w bounds])) {
            [w setBounds:full];
            AIFixWindow(w);
        }
    }

    rvc = [w rootViewController];
    rv = [rvc view];
    AIFixViewRecursively(rv, 0, full);

    AIFixTextWindows();
}

#pragma mark - ══════════════ 键盘 ══════════════

/* 0x456c：键盘弹出时把输入框所在的分支重新对齐 */
static void AIOnKeyboardWillShow(NSNotification *note)
{
    CGRect full = AIFullscreenRect();
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return;

    NSValue *v = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (v) {
        CGRect kb = [v CGRectValue];
        gKeyboardEndY = kb.origin.y;
    }

    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;

    UIWindow *target = nil;
    for (UIWindow *w in [app windows]) {
        if (AIWindowIsCandidate(w, full)) { target = w; break; }
    }
    if (!target) target = [[app windows] firstObject];
    if (!target) return;

    /* 从第一响应者往上找可以被改写高度的那一层，最多 11 层 */
    UIView *responder = AIFindFirstResponder(target);
    if ([responder superview]) {
        UIView *sup = [responder superview];
        for (NSInteger i = 0; i < 11; i++) {
            if (!gIsFixing) {
                CGRect b = [sup bounds];
                if (fabs(b.size.width  - full.size.width ) <  1.0 &&
                    fabs(b.size.height - full.size.height) >  1.0 &&
                    gStaleHeight > 100.0                          &&
                    fabs(b.size.height - gStaleHeight)    <  3.0  &&
                    fabs([sup frame].origin.y)            <  1.0  &&
                    !AIClassIsIgnored(sup))
                {
                    gIsFixing = YES;
                    gStaleHeight = b.size.height;
                    AIApplyRect(sup, full);
                    gIsFixing = NO;
                    break;
                }
            }
            UIView *next = [sup superview];
            if (!next) break;
            sup = next;
        }
    }

    AIFixTextWindows();

    /* 键盘动画之后再补一刀 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGRect f2 = AIFullscreenRect();
        if (!CGRectEqualToRect([UIScreen mainScreen].bounds, f2)) return;
        AIFixTextWindows();

        gIsFixing = YES;
        AIFixWindow(gTargetWindow);
        gIsFixing = NO;

        UIApplication *a2 = [UIApplication sharedApplication];
        for (UIWindow *w in [a2 windows]) {
            if (!AIWindowIsCandidate(w, f2)) continue;
            UIView *rv = [[w rootViewController] view];
            AIFixViewRecursively(rv, 0, f2);
        }
        AIFixTextWindows();
    });
}

#pragma mark - ══════════════ Hook 实现 ══════════════

/*
 * -[UIWindow setBounds:]
 * 窗口被重设为错误比例的高度时，改写成全屏高度，然后把内容重新对齐。
 */
static void hooked_UIWindow_setBounds(UIWindow *self, SEL _cmd, CGRect bounds)
{
    CGRect full = AIFullscreenRect();

    if (CGRectEqualToRect([UIScreen mainScreen].bounds, full)) {
        NSString *name = NSStringFromClass([self class]);
        if (AINameIsHostWindow(name) && bounds.size.height > 50.0) {
            if (fabs(bounds.size.height - full.size.height) > 1.0) {
                orig_UIWindow_setBounds(self, _cmd,
                    CGRectMake(bounds.origin.x, bounds.origin.y,
                               bounds.size.width, full.size.height));
                return;
            }
        }
    }

    if (!gIsFixing) {
        if (CGRectEqualToRect([UIScreen mainScreen].bounds, full) &&
            AIWindowIsCandidate(self, full) &&
            fabs(bounds.size.height - full.size.height) > 1.0)
        {
            gIsFixing    = YES;
            gStaleHeight = bounds.size.height;
            AILog(@"fix window %@ h=%.1f -> %.1f", NSStringFromClass([self class]),
                  bounds.size.height, full.size.height);
            orig_UIWindow_setBounds(self, _cmd, full);
            AIFixWindow(self);
            AIFixAllWindows();
            gIsFixing    = NO;
            return;
        }
    }

    orig_UIWindow_setBounds(self, _cmd, bounds);
}

/* -[UIView setBounds:] */
static void hooked_UIView_setBounds(UIView *self, SEL _cmd, CGRect bounds)
{
    if (!gIsFixing && AIViewNeedsFullscreenFix(self, bounds)) {
        CGRect full = AIFullscreenRect();
        gIsFixing    = YES;
        gStaleHeight = bounds.size.height;
        orig_UIView_setBounds(self, _cmd, full);
        if (!(self == gSavedRootView && gTargetWindow != nil)) {
            AIFixWindow(gTargetWindow);
        }
        gIsFixing = NO;
        return;
    }
    orig_UIView_setBounds(self, _cmd, bounds);
}

/* layoutSubviews 之后统一补修一次（宿主窗口内的容器）*/
static void AIAfterLayout(UIView *view)
{
    if (!view || gIsFixing) return;

    CGRect full = AIFullscreenRect();
    if (!CGRectEqualToRect([UIScreen mainScreen].bounds, full)) return;

    UIView *host = nil;
    UIView *cur  = [view superview];
    for (NSInteger i = 0; i < 10 && cur; i++) {
        if ([cur isKindOfClass:[UIWindow class]]) { host = cur; break; }
        cur = [cur superview];
    }
    if (!host) return;

    CGRect b = [view bounds];
    if (fabs(b.size.width - full.size.width) >= 1.0) return;
    if (AIClassIsIgnored(view)) return;
    if ([view isKindOfClass:[UIScrollView class]]) return;
    if (fabs(b.size.height - full.size.height) <= 1.0) return;
    if (gStaleHeight <= 100.0) return;
    if (fabs(b.size.height - gStaleHeight) >= 3.0) return;

    gIsFixing    = YES;
    gStaleHeight = b.size.height;
    AIApplyRect(view, full);
    AIFixWindow((UIWindow *)host);
    gIsFixing    = NO;
}

static void hooked_UILayoutContainerView_layoutSubviews(UIView *self, SEL _cmd)
{
    orig_UILayoutContainerView_layoutSubviews(self, _cmd);
    AIAfterLayout(self);
}

static void hooked_UITransitionView_layoutSubviews(UIView *self, SEL _cmd)
{
    orig_UITransitionView_layoutSubviews(self, _cmd);
    AIAfterLayout(self);
}

/* App 私有容器：类名命中才 hook，命中不到就是空钩子 */
static void hooked_AppContainer_layoutSubviews(UIView *self, SEL _cmd)
{
    Class cls = [self class];
    for (NSUInteger i = 0; i < kAppContainerClassCount; i++) {
        if (gExtraHooks[i].cls == cls && gExtraHooks[i].origLayout) {
            ((void (*)(id, SEL))gExtraHooks[i].origLayout)(self, _cmd);
            break;
        }
    }
    AIAfterLayout(self);
}

static void hooked_AppContainer_setBounds(UIView *self, SEL _cmd, CGRect bounds)
{
    Class cls = [self class];
    IMP orig = NULL;
    for (NSUInteger i = 0; i < kAppContainerClassCount; i++) {
        if (gExtraHooks[i].cls == cls) { orig = gExtraHooks[i].origBounds; break; }
    }
    if (orig) ((void (*)(id, SEL, CGRect))orig)(self, _cmd, bounds);
    AIAfterLayout(self);
}

/*
 * -[UITabBar setBounds:]
 * 底部标签栏在比例被改后会停在旧的底边上，把它挪到修正后的底边。
 */
static void hooked_UITabBar_setBounds(UIView *self, SEL _cmd, CGRect bounds)
{
    CGRect full = AIFullscreenRect();
    if (CGRectEqualToRect([UIScreen mainScreen].bounds, full) &&
        bounds.size.height > 40.0 && bounds.size.height < 200.0 &&
        gStaleHeight > 100.0)
    {
        CGRect f = [self frame];
        if (fabs(CGRectGetMaxY(f) - gStaleHeight) < 2.0) {
            CGRect fixed = bounds;
            fixed.origin.y = full.size.height - bounds.size.height;
            orig_UITabBar_setBounds(self, _cmd, fixed);
            return;
        }
    }
    orig_UITabBar_setBounds(self, _cmd, bounds);
}

#pragma mark - ══════════════ 安装 ══════════════

static void AIInstallHooks(void)
{
#define AIHookMsg(cls, sel, newImp, origPtr)                     \
    MSHookMessageEx((cls), (sel), (IMP)(newImp), (IMP *)(origPtr))

    Class c;

    c = objc_getClass("UIWindow");
    if (c) AIHookMsg(c, @selector(setBounds:), hooked_UIWindow_setBounds, &orig_UIWindow_setBounds);

    c = objc_getClass("UIView");
    if (c) AIHookMsg(c, @selector(setBounds:), hooked_UIView_setBounds, &orig_UIView_setBounds);

    c = objc_getClass("UILayoutContainerView");
    if (c) AIHookMsg(c, @selector(layoutSubviews),
                     hooked_UILayoutContainerView_layoutSubviews,
                     &orig_UILayoutContainerView_layoutSubviews);

    c = objc_getClass("UITransitionView");
    if (c) AIHookMsg(c, @selector(layoutSubviews),
                     hooked_UITransitionView_layoutSubviews,
                     &orig_UITransitionView_layoutSubviews);

    c = objc_getClass("UITabBar");
    if (c) AIHookMsg(c, @selector(setBounds:), hooked_UITabBar_setBounds, &orig_UITabBar_setBounds);

    for (NSUInteger i = 0; i < kAppContainerClassCount; i++) {
        Class cc = objc_getClass([kAppContainerClasses[i] UTF8String]);
        gExtraHooks[i].cls = cc;
        if (!cc) continue;
        AIHookMsg(cc, @selector(layoutSubviews), hooked_AppContainer_layoutSubviews, &gExtraHooks[i].origLayout);
        AIHookMsg(cc, @selector(setBounds:),  hooked_AppContainer_setBounds,  &gExtraHooks[i].origBounds);
    }

#undef AIHookMsg
}

/* 0.5s 一轮的心跳，用来兜住 App 自己把布局改回去的情况 */
static void AIWatchdog(void)
{
    AICheckAndFix();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ AIWatchdog(); });
}

__attribute__((constructor))
static void AlipayFullscreenFixInit(void)
{
    @autoreleasepool {
        /* 这条日志是用来确认「插件确实被注入了」的。
           在设备控制台 /Filza 里看不到这行，说明是注入器没加载。 */
        NSLog(@"[AlipayFullscreenFix] loaded into %@ (%@)",
              [[NSBundle mainBundle] bundleIdentifier],
              NSStringFromCGRect([UIScreen mainScreen].bounds));

        AIInstallHooks();

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        NSOperationQueue     *mq = [NSOperationQueue mainQueue];

        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:mq
                    usingBlock:^(NSNotification *note) { AICheckAndFix(); }];

        [nc addObserverForName:UIKeyboardWillShowNotification
                        object:nil
                         queue:mq
                    usingBlock:^(NSNotification *note) { AIOnKeyboardWillShow(note); }];

        /* 首屏起来得晚一点，2s 后再动手；随后进入 0.5s 心跳 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AIFixAllWindows();
            AIWatchdog();
        });
    }
}
