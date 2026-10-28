//
//  DoraemonEntryWindow.m
//  DoraemonKit
//
//  Created by yixiang on 2017/12/11.
//  Copyright © 2017年 yixiang. All rights reserved.
//

#import "DoraemonEntryWindow.h"
#import "DoraemonDefine.h"
#import "UIView+Doraemon.h"
#import "UIImage+Doraemon.h"
#import "DoraemonDefine.h"
#import "DoraemonHomeWindow.h"
#import "DoraemonStatusBarViewController.h"

/// 铺满 App 主窗口、垫在最底层的空视图。折叠屏开合、转屏时主窗口的尺寸和安全区先后变化，
/// 每次变化都通知入口重新停靠；它的安全区就是主窗口的安全区
@interface DoraemonEntryGeometryProbe : UIView
@property (nonatomic, copy) void (^geometryDidChange)(void);
@end

@implementation DoraemonEntryGeometryProbe {
    CGSize _lastSize;
    UIEdgeInsets _lastInsets;
    BOOL _hasReported;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self reportIfChanged];
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self reportIfChanged];
}

- (void)reportIfChanged {
    CGSize size = self.bounds.size;
    UIEdgeInsets insets = self.safeAreaInsets;
    BOOL changed = !_hasReported || !CGSizeEqualToSize(size, _lastSize) || !UIEdgeInsetsEqualToEdgeInsets(insets, _lastInsets);
    _lastSize = size;
    _lastInsets = insets;
    _hasReported = YES;
    if (changed && self.geometryDidChange) {
        self.geometryDidChange();
    }
}

@end

@interface DoraemonEntryWindow()

@property (nonatomic, strong) UIButton *entryBtn;
@property (nonatomic, assign) CGFloat kEntryViewSize;
@property (nonatomic) CGPoint startingPosition;
@property (nonatomic, strong) UILabel *entryBtnBlingTextLabel;
/// 停靠在右侧还是左侧，以及停靠的纵向位置；容器尺寸变化（折叠屏开合、转屏）后按它们重新停靠。
/// 不能读当时的 center：系统在 scene 尺寸变化时会改动这个小窗口的位置
@property (nonatomic, assign) BOOL dockedToRight;
@property (nonatomic, assign) CGFloat dockedCenterY;
@property (nonatomic, strong) DoraemonEntryGeometryProbe *geometryProbe;
@property (nonatomic, assign) BOOL redockScheduled;
/// 正在由本类写入几何（停靠、拖动），此时的几何变化不算外部改动
@property (nonatomic, assign) BOOL applyingOwnGeometry;
@property (nonatomic, assign) BOOL geometryReady;
@property (nonatomic, assign) NSUInteger lateRedockToken;

@end

@implementation DoraemonEntryWindow

- (UIButton *)entryBtn {
    if (!_entryBtn) {
        _entryBtn = [[UIButton alloc] initWithFrame:self.bounds];
        _entryBtn.backgroundColor = [UIColor clearColor];
        UIImage *image = [UIImage doraemon_xcassetImageNamed:@"doraemon_logo"];
#if defined(__IPHONE_13_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_13_0)
        if (@available(iOS 13.0, *)) {
            if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                image = [UIImage doraemon_xcassetImageNamed:@"doraemon_logo_dark"];
            }
        }
#endif
        [_entryBtn setImage:image forState:UIControlStateNormal];
        _entryBtn.layer.cornerRadius = 20.;
        [_entryBtn addTarget:self action:@selector(entryClick:) forControlEvents:UIControlEventTouchUpInside];
    }

    return _entryBtn;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // trait发生了改变
#if defined(__IPHONE_13_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_13_0)
    if (@available(iOS 13.0, *)) {
        if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            if (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
                [self.entryBtn setImage:[UIImage doraemon_xcassetImageNamed:@"doraemon_logo_dark"] forState:UIControlStateNormal];
            } else {
                [self.entryBtn setImage:[UIImage doraemon_xcassetImageNamed:@"doraemon_logo"] forState:UIControlStateNormal];
            }
        }
    }
#endif
}

- (instancetype)initWithStartPoint:(CGPoint)startingPosition{
    self.startingPosition = startingPosition;
    _kEntryViewSize = 58;
    CGFloat x = self.startingPosition.x;
    CGFloat y = self.startingPosition.y;
    CGPoint defaultPosition = DoraemonStartingPosition;
    if (x < 0 || x > (DoraemonScreenWidth - _kEntryViewSize)) {
        x = defaultPosition.x;
    }
    
    if (y < 0 || y > (DoraemonScreenHeight - _kEntryViewSize)) {
        y = defaultPosition.y;
    }
    
    self = [super initWithFrame:CGRectMake(x, y, _kEntryViewSize, _kEntryViewSize)];
    if (self) {
        #if defined(__IPHONE_13_0) && (__IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_13_0)
            if (@available(iOS 13.0, *)) {
                UIScene *scene = [[UIApplication sharedApplication].connectedScenes anyObject];
                if (scene) {
                    self.windowScene = (UIWindowScene *)scene;
                }
            }
        #endif
        self.backgroundColor = [UIColor clearColor];
        self.windowLevel = UIWindowLevelStatusBar + 100.f;
        self.layer.masksToBounds = YES;
        
        // 统一使用 DoraemonStatusBarViewController
        // 对系统的版本处理放入 DoraemonStatusBarViewController 类中
        if (!self.rootViewController) {
            self.rootViewController = [[DoraemonStatusBarViewController alloc] init];
        }

        
        [self.rootViewController.view addSubview:self.entryBtn];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [self addGestureRecognizer:pan];

        self.dockedToRight = self.center.x > CGRectGetWidth([self containerBounds]) / 2.f;
        self.dockedCenterY = self.center.y;
        [self installGeometryProbeIfNeeded];
        self.geometryReady = YES;
    }
    return self;
}

/// 调试入口不需要成为 key window；成为 key 后会参与 scene 尺寸、方向变化的处理
- (BOOL)canBecomeKeyWindow {
    return NO;
}

#pragma mark - External geometry changes

/// 折叠屏开合时，系统会在入口停靠之后再按 scene 尺寸比例改动这个小窗口（真机上横向压缩到约一半），
/// 主窗口此后不再变化、探针不会再报告；入口自己发现几何被外部改动时重新停靠
- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self geometryDidChangeExternally];
}

- (void)setBounds:(CGRect)bounds {
    [super setBounds:bounds];
    [self geometryDidChangeExternally];
}

- (void)setCenter:(CGPoint)center {
    [super setCenter:center];
    [self geometryDidChangeExternally];
}

- (void)setTransform:(CGAffineTransform)transform {
    [super setTransform:transform];
    [self geometryDidChangeExternally];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(self.bounds.size, CGSizeMake(_kEntryViewSize, _kEntryViewSize))) {
        [self geometryDidChangeExternally];
    }
}

- (void)geometryDidChangeExternally {
    if (!self.geometryReady || self.applyingOwnGeometry) {
        return;
    }
    [self scheduleRedock];
}

- (void)performOwnGeometryChange:(void (^)(void))changes {
    BOOL wasApplying = self.applyingOwnGeometry;
    self.applyingOwnGeometry = YES;
    changes();
    self.applyingOwnGeometry = wasApplying;
}

#pragma mark - Container

/// App 主窗口：本 scene 的 key window，没有时取第一个铺满 scene 的可见窗口
- (UIWindow *)mainWindow {
    if (@available(iOS 15.0, *)) {
        UIWindow *keyWindow = self.windowScene.keyWindow;
        if (keyWindow && keyWindow != self) {
            return keyWindow;
        }
    }
    if (@available(iOS 13.0, *)) {
        CGRect bounds = [self containerBounds];
        for (UIWindow *window in self.windowScene.windows) {
            if (window != self && !window.hidden && CGRectEqualToRect(window.frame, bounds)) {
                return window;
            }
        }
    }
    return nil;
}

- (void)installGeometryProbeIfNeeded {
    UIWindow *mainWindow = [self mainWindow];
    if (!mainWindow || self.geometryProbe.superview == mainWindow) {
        return;
    }
    [self.geometryProbe removeFromSuperview];
    DoraemonEntryGeometryProbe *probe = [[DoraemonEntryGeometryProbe alloc] initWithFrame:mainWindow.bounds];
    __weak typeof(self) weakSelf = self;
    probe.geometryDidChange = ^{
        [weakSelf scheduleRedock];
        [weakSelf scheduleLateRedock];
    };
    [mainWindow insertSubview:probe atIndex:0];
    self.geometryProbe = probe;
}

/// 所在 scene 的可见区域；折叠屏上 UIScreen.mainScreen 始终报告外屏尺寸，不能用来定位
- (CGRect)containerBounds {
    if (@available(iOS 13.0, *)) {
        if (self.windowScene) {
            return self.windowScene.coordinateSpace.bounds;
        }
    }
    return [UIScreen mainScreen].bounds;
}

/// App 主窗口的安全区（含状态栏、折叠屏的系统竖条）；本窗口只有入口大小，自身的安全区没有意义
- (UIEdgeInsets)containerSafeAreaInsets {
    if (self.geometryProbe.window) {
        return self.geometryProbe.safeAreaInsets;
    }
    return [self mainWindow].safeAreaInsets;
}

/// 按停靠的一侧贴边，并把纵向位置限制在安全区内
- (CGPoint)dockedCenterForY:(CGFloat)y {
    CGRect bounds = [self containerBounds];
    UIEdgeInsets insets = [self containerSafeAreaInsets];
    CGFloat half = _kEntryViewSize / 2.f;
    CGFloat centerX = self.dockedToRight ? CGRectGetWidth(bounds) - insets.right - half : insets.left + half;
    CGFloat minY = insets.top + half;
    CGFloat maxY = CGRectGetHeight(bounds) - insets.bottom - half;
    CGFloat centerY = MAX(MIN(y, maxY), minY);
    return CGPointMake(centerX, centerY);
}

/// 布局过程中系统还会调整这个小窗口的位置（转屏时重新映射坐标），等这一轮结束再停靠；同一轮内多次请求合并为一次
- (void)scheduleRedock {
    if (self.redockScheduled) {
        return;
    }
    self.redockScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.redockScheduled = NO;
        [self redockInContainer];
    });
}

/// 开合过渡结束后再停靠一次：系统对这个窗口的改动可能晚于主窗口的变化，也可能不经过上面的 setter
- (void)scheduleLateRedock {
    NSUInteger token = ++self.lateRedockToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.lateRedockToken == token) {
            [weakSelf redockInContainer];
        }
    });
}

- (void)redockInContainer {
    CGPoint center;
    if (self.autoDock) {
        center = [self dockedCenterForY:self.dockedCenterY];
    } else {
        CGRect bounds = [self containerBounds];
        CGFloat half = _kEntryViewSize / 2.f;
        CGFloat centerX = MAX(MIN(self.center.x, CGRectGetWidth(bounds) - half), half);
        CGFloat centerY = MAX(MIN(self.center.y, CGRectGetHeight(bounds) - half), half);
        center = CGPointMake(centerX, centerY);
    }
    [self applyEntryGeometryWithCenter:center];
}

/// 恢复入口的完整几何：无变换、原始尺寸、给定中心
- (void)applyEntryGeometryWithCenter:(CGPoint)center {
    [self performOwnGeometryChange:^{
        self.transform = CGAffineTransformIdentity;
        self.layer.transform = CATransform3DIdentity;
        self.bounds = CGRectMake(0, 0, self->_kEntryViewSize, self->_kEntryViewSize);
        self.center = center;
        UIView *rootView = self.rootViewController.view;
        rootView.transform = CGAffineTransformIdentity;
        rootView.frame = self.bounds;
        self.entryBtn.transform = CGAffineTransformIdentity;
        self.entryBtn.frame = rootView.bounds;
    }];
}

- (void)show{
    self.hidden = NO;
    [self installGeometryProbeIfNeeded];
    [self scheduleRedock];
}

- (void)showClose:(NSNotification *)notification{
    [_entryBtn setImage:[UIImage doraemon_xcassetImageNamed:@"doraemon_close"] forState:UIControlStateNormal];
    [_entryBtn removeTarget:self action:@selector(showClose:) forControlEvents:UIControlEventTouchUpInside];
    [_entryBtn addTarget:self action:@selector(closePluginClick:) forControlEvents:UIControlEventTouchUpInside];
}

- (void)closePluginClick:(UIButton *)btn{
    [_entryBtn setImage:[UIImage doraemon_xcassetImageNamed:@"doraemon_logo"] forState:UIControlStateNormal];
    [_entryBtn removeTarget:self action:@selector(closePluginClick:) forControlEvents:UIControlEventTouchUpInside];
    [_entryBtn addTarget:self action:@selector(entryClick:) forControlEvents:UIControlEventTouchUpInside];
}

/**
 进入工具主面板
 */
- (void)entryClick:(UIButton *)btn{
    if ([DoraemonHomeWindow shareInstance].hidden) {
        [[DoraemonHomeWindow shareInstance] show];
    }else{
        [[DoraemonHomeWindow shareInstance] hide];
    }
}

- (void)pan:(UIPanGestureRecognizer *)pan{
    if (self.autoDock) {
        [self autoDocking:pan];
    }else{
        [self normalMode:pan];
    }
}

- (void)normalMode: (UIPanGestureRecognizer *)panGestureRecognizer{
    //1、获得拖动位移
    CGPoint offsetPoint = [panGestureRecognizer translationInView:panGestureRecognizer.view];
    //2、清空拖动位移
    [panGestureRecognizer setTranslation:CGPointZero inView:panGestureRecognizer.view];
    //3、重新设置控件位置
    UIView *panView = panGestureRecognizer.view;
    CGFloat newX = panView.doraemon_centerX+offsetPoint.x;
    CGFloat newY = panView.doraemon_centerY+offsetPoint.y;
    CGRect bounds = [self containerBounds];
    if (newX < _kEntryViewSize/2) {
        newX = _kEntryViewSize/2;
    }
    if (newX > CGRectGetWidth(bounds) - _kEntryViewSize/2) {
        newX = CGRectGetWidth(bounds) - _kEntryViewSize/2;
    }
    if (newY < _kEntryViewSize/2) {
        newY = _kEntryViewSize/2;
    }
    if (newY > CGRectGetHeight(bounds) - _kEntryViewSize/2) {
        newY = CGRectGetHeight(bounds) - _kEntryViewSize/2;
    }
    [self performOwnGeometryChange:^{
        panView.center = CGPointMake(newX, newY);
    }];
}

- (void)autoDocking:(UIPanGestureRecognizer *)panGestureRecognizer {
    UIView *panView = panGestureRecognizer.view;
    switch (panGestureRecognizer.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
        {
            CGPoint translation = [panGestureRecognizer translationInView:panView];
            [panGestureRecognizer setTranslation:CGPointZero inView:panView];
            [self performOwnGeometryChange:^{
                panView.center = CGPointMake(panView.center.x + translation.x, panView.center.y + translation.y);
            }];
        }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        {
            CGPoint location = panView.center;
            self.dockedToRight = location.x > CGRectGetWidth([self containerBounds]) / 2.f;
            CGPoint docked = [self dockedCenterForY:location.y];
            self.dockedCenterY = docked.y;
            [[NSUserDefaults standardUserDefaults] setObject:@{
                                                               @"x":[NSNumber numberWithFloat:docked.x],
                                                               @"y":[NSNumber numberWithFloat:docked.y],
                                                               @"right":@(self.dockedToRight)
                                                               } forKey:@"FloatViewCenterLocation"];
            [UIView animateWithDuration:0.3 animations:^{
                [self performOwnGeometryChange:^{
                    panView.center = docked;
                }];
            }];
        }

        default:
            break;
    }
}

- (void)setAutoDock:(BOOL)autoDock {
    _autoDock = autoDock;
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] objectForKey:@"FloatViewCenterLocation"];
    if (dict && dict[@"x"] && dict[@"y"]) {
        self.center = CGPointMake([dict[@"x"] integerValue], [dict[@"y"] integerValue]);
    }
    // 保存的坐标可能来自另一块屏幕（折叠屏外屏/内屏），停靠侧以保存的为准，再按当前容器重新停靠
    if (dict[@"right"]) {
        self.dockedToRight = [dict[@"right"] boolValue];
    } else {
        self.dockedToRight = self.center.x > CGRectGetWidth([self containerBounds]) / 2.f;
    }
    self.dockedCenterY = self.center.y;
    [self scheduleRedock];
}

- (void)configEntryBtnBlingWithText:(NSString *)text backColor:(UIColor *)backColor {

    if (text == nil || text.length == 0) {
        [self destoryBlingText];
        return;
    }
    backColor = backColor ?: [UIColor whiteColor];

    if (!self.entryBtnBlingTextLabel) {
        self.entryBtnBlingTextLabel = [[UILabel alloc] initWithFrame:self.entryBtn.bounds];
        self.entryBtnBlingTextLabel.transform = CGAffineTransformMakeScale(0.6, 0.6);
        [self.entryBtn addSubview:self.entryBtnBlingTextLabel];
        self.entryBtnBlingTextLabel.layer.cornerRadius = self.entryBtnBlingTextLabel.bounds.size.width/2.0;
        self.entryBtnBlingTextLabel.clipsToBounds = YES;
        self.entryBtnBlingTextLabel.font = [UIFont systemFontOfSize:self.entryBtn.bounds.size.width - 10];
        self.entryBtnBlingTextLabel.textAlignment = NSTextAlignmentCenter;
        self.entryBtnBlingTextLabel.textColor = [UIColor whiteColor];
        CABasicAnimation* animation = [CABasicAnimation animationWithKeyPath:@"opacity"];
        animation.fromValue = @1;
        animation.toValue = @0;
        animation.duration = 3.0;
        animation.beginTime = CACurrentMediaTime() + 0;
        animation.repeatCount = HUGE_VALF ;
        animation.autoreverses = YES;
        animation.timingFunction = [CAMediaTimingFunction functionWithName: kCAMediaTimingFunctionEaseInEaseOut];
        animation.fillMode = kCAFillModeForwards;
        [self.entryBtnBlingTextLabel.layer addAnimation:animation forKey:@"bling"];
    }
    self.entryBtnBlingTextLabel.backgroundColor = backColor;
    self.entryBtnBlingTextLabel.text = [text substringToIndex:1];
    
}

- (void)destoryBlingText {
    [self.entryBtnBlingTextLabel.layer removeAllAnimations];
    [self.entryBtnBlingTextLabel removeFromSuperview];
    self.entryBtnBlingTextLabel = nil;
}
@end
