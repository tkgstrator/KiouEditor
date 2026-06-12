#import "Internal.h"
#import <UIKit/UIKit.h>

// ===========================================================================
// Phase 2e/2h: UIKit-backed settings modal.
//
// Presented from the OnPointerClick hook in Hook_FriendUnhide.m when the
// menu-button clone is tapped. Lives entirely in iOS land so we sidestep
// the Unity UI / IL2CPP stack: a UIViewController is pushed on top of the
// active UIWindow via standard UIKit.
//
// Layout: grouped UITableView with two sections.
//   - "Features" - one UISwitch per KiouFeature, flipping a feature flag
//     reflects on the next hook fire (no restart needed, except for the
//     home-screen friend button + clone which only refresh on a TitleScene
//     -> Home transition).
//   - "Engine"   - depth / skill steppers feeding BeginnerSupportEvaluator
//     and ResolvedBeginnerSupport.get_Depth.
// ===========================================================================

@interface KEditorSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel     *depthValueLabel;
@property (nonatomic, strong) UILabel     *skillValueLabel;
@property (nonatomic, strong) UILabel     *hashValueLabel;
@end

// Mirror of the preset table in Persistence.m. Kept in this file (instead of
// exposing the array through Internal.h) so the UI can render labels with
// "<MB> MB" formatting locally; kiou_assistHashMB() is the source of truth
// for hooks and is what gets sent to NativeSyncSession.SetHashSize.
static const int32_t kHashPresetsMB[] = { 64, 128, 256, 512, 1024 };
#define KE_HASH_PRESET_COUNT \
    ((int32_t)(sizeof(kHashPresetsMB) / sizeof(kHashPresetsMB[0])))

@implementation KEditorSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"KiouEditor";

    UINavigationBar *navBar = [[UINavigationBar alloc] init];
    navBar.translatesAutoresizingMaskIntoConstraints = NO;
    UINavigationItem *navItem = [[UINavigationItem alloc] initWithTitle:@"Kiou Editor"];
    navItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(onClose:)];
    navBar.items = @[ navItem ];
    [self.view addSubview:navBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero
                                                  style:UITableViewStyleInsetGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate   = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [navBar.topAnchor      constraintEqualToAnchor:safe.topAnchor],
        [navBar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [navBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [self.tableView.topAnchor      constraintEqualToAnchor:navBar.bottomAnchor],
        [self.tableView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)onClose:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// ---------------------------------------------------------------------------
// UITableViewDataSource / Delegate
// ---------------------------------------------------------------------------

#define KE_SECTION_FEATURES 0
#define KE_SECTION_ENGINE   1
#define KE_SECTION_ABOUT    2
#define KE_SECTION_COUNT    3

#define KE_ENGINE_ROW_DEPTH 0
#define KE_ENGINE_ROW_SKILL 1
#define KE_ENGINE_ROW_HASH  2
#define KE_ENGINE_ROW_COUNT 3

#define KE_ABOUT_ROW_REPO    0
#define KE_ABOUT_ROW_TWITTER 1
#define KE_ABOUT_ROW_COUNT   2

static NSString *const kAboutRepoURL    = @"https://github.com/tkgstrator/KiouEditor";
static NSString *const kAboutTwitterURL = @"https://x.com/tkgling";

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return KE_SECTION_COUNT;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case KE_SECTION_FEATURES: return @"Features";
        case KE_SECTION_ENGINE:   return @"Engine";
        case KE_SECTION_ABOUT:    return @"About";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == KE_SECTION_FEATURES) {
        return @"Toggles take effect on the next hook fire. Home-screen "
               @"changes (friend button + settings clone) need a return "
               @"to the title and back.";
    }
    if (section == KE_SECTION_ENGINE) {
        return @"Depth feeds both the in-game evaluator and the hint-arrow "
               @"path. Higher depth = stronger but heavier per move. Hash "
               @"is the NNUE transposition-table size; the engine never "
               @"sets it without this tweak.";
    }
    if (section == KE_SECTION_ABOUT) {
        return [NSString stringWithFormat:@"build %s", KIOU_EDITOR_COMMIT];
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case KE_SECTION_FEATURES: return KIOU_FEATURE_COUNT;
        case KE_SECTION_ENGINE:   return KE_ENGINE_ROW_COUNT;
        case KE_SECTION_ABOUT:    return KE_ABOUT_ROW_COUNT;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == KE_SECTION_FEATURES) {
        static NSString *kId = @"feature";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:kId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        KiouFeature f = (KiouFeature)indexPath.row;
        cell.textLabel.text = kiou_featureLabel(f);

        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = kiou_featureEnabled(f);
        sw.tag = f;
        [sw addTarget:self
               action:@selector(onFeatureToggle:)
     forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        return cell;
    }

    if (indexPath.section == KE_SECTION_ENGINE) {
        static NSString *kId = @"engine";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                          reuseIdentifier:kId];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        // Always rebuild the stepper to bind the latest accessor.
        cell.accessoryView = nil;
        UIStepper *stepper = [[UIStepper alloc] init];
        stepper.continuous = NO;
        if (indexPath.row == KE_ENGINE_ROW_DEPTH) {
            cell.textLabel.text = @"Depth";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d",
                                         (int)kiou_assistDepth()];
            self.depthValueLabel = cell.detailTextLabel;
            stepper.minimumValue = 1;
            stepper.maximumValue = 36;
            stepper.value = kiou_assistDepth();
            [stepper addTarget:self
                        action:@selector(onDepthChanged:)
              forControlEvents:UIControlEventValueChanged];
        } else if (indexPath.row == KE_ENGINE_ROW_SKILL) {
            cell.textLabel.text = @"Skill Level";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d",
                                         (int)kiou_assistSkillLevel()];
            self.skillValueLabel = cell.detailTextLabel;
            stepper.minimumValue = 1;
            stepper.maximumValue = 20;
            stepper.value = kiou_assistSkillLevel();
            [stepper addTarget:self
                        action:@selector(onSkillChanged:)
              forControlEvents:UIControlEventValueChanged];
        } else { // KE_ENGINE_ROW_HASH
            cell.textLabel.text = @"Hash";
            int32_t idx = kiou_assistHashIndex();
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d MB",
                                         (int)kHashPresetsMB[idx]];
            self.hashValueLabel = cell.detailTextLabel;
            stepper.minimumValue = 0;
            stepper.maximumValue = KE_HASH_PRESET_COUNT - 1;
            stepper.stepValue    = 1;
            stepper.value        = idx;
            [stepper addTarget:self
                        action:@selector(onHashChanged:)
              forControlEvents:UIControlEventValueChanged];
        }
        cell.accessoryView = stepper;
        return cell;
    }

    // About section
    static NSString *kId = @"about";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kId];
    }
    if (indexPath.row == KE_ABOUT_ROW_REPO) {
        cell.textLabel.text       = @"GitHub";
        cell.detailTextLabel.text = kAboutRepoURL;
    } else {
        cell.textLabel.text       = @"Author (X)";
        cell.detailTextLabel.text = kAboutTwitterURL;
    }
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != KE_SECTION_ABOUT) return;
    NSString *str = (indexPath.row == KE_ABOUT_ROW_REPO)
                  ? kAboutRepoURL : kAboutTwitterURL;
    NSURL *url = [NSURL URLWithString:str];
    if (url) {
        [UIApplication.sharedApplication openURL:url
                                         options:@{}
                               completionHandler:nil];
    }
}

// ---------------------------------------------------------------------------
// Control handlers
// ---------------------------------------------------------------------------

- (void)onFeatureToggle:(UISwitch *)sw {
    KiouFeature f = (KiouFeature)sw.tag;
    kiou_setFeatureEnabled(f, sw.isOn);
    file_log([NSString stringWithFormat:
              @"[SETTINGS] feature %@ -> %@",
              kiou_featureLabel(f), sw.isOn ? @"ON" : @"OFF"]);
}

- (void)onDepthChanged:(UIStepper *)stepper {
    int32_t v = (int32_t)stepper.value;
    kiou_setAssistDepth(v);
    self.depthValueLabel.text = [NSString stringWithFormat:@"%d", v];
    file_log([NSString stringWithFormat:@"[SETTINGS] assist depth -> %d", v]);
}

- (void)onSkillChanged:(UIStepper *)stepper {
    int32_t v = (int32_t)stepper.value;
    kiou_setAssistSkillLevel(v);
    self.skillValueLabel.text = [NSString stringWithFormat:@"%d", v];
    file_log([NSString stringWithFormat:@"[SETTINGS] assist skill -> %d", v]);
}

- (void)onHashChanged:(UIStepper *)stepper {
    int32_t idx = (int32_t)stepper.value;
    kiou_setAssistHashIndex(idx);
    int32_t mb = kHashPresetsMB[kiou_assistHashIndex()];
    self.hashValueLabel.text = [NSString stringWithFormat:@"%d MB", mb];
    file_log([NSString stringWithFormat:
              @"[SETTINGS] assist hash -> %d MB (idx=%d)", mb, idx]);
}

@end

// ---------------------------------------------------------------------------
// Presenter bridge - called from the OnPointerClick hook.
// ---------------------------------------------------------------------------

static UIWindow *activeWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (!app) return nil;
    UIWindow *fallback = nil;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

void kioueditor_presentSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = activeWindow();
        if (!win) {
            file_log(@"[SETTINGS] no active window");
            return;
        }
        UIViewController *root = win.rootViewController;
        if (!root) {
            file_log(@"[SETTINGS] no root view controller");
            return;
        }
        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;

        KEditorSettingsViewController *vc = [[KEditorSettingsViewController alloc] init];
        vc.modalPresentationStyle = UIModalPresentationFormSheet;
        [top presentViewController:vc animated:YES completion:^{
            file_log(@"[SETTINGS] modal presented");
        }];
    });
}
