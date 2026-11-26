#import "AUOwnPage.h"
#import "Core/AUCore.h"
#import <objc/runtime.h>

@implementation AUOwnRow
@end

@implementation AUOwnSection
@end

static BOOL rowWaiting(AUOwnRow *row) {
    return row.waitsOn.length && !AUEnabled(row.waitsOn);
}

static BOOL switchOn(AUOwnRow *row) {
    return row.kind == AUOwnRowOption ? AUFlag(row.key) : AUEnabled(row.key);
}

static NSString *choiceValue(AUOwnRow *row) {
    NSInteger index = AUInteger(row.key, row.fallback);
    if (index < 0 || index >= (NSInteger)row.choices.count) index = 0;
    return row.choices.count ? row.choices[(NSUInteger)index] : @"";
}

#pragma mark - a choice

@interface AUOwnChoicePage : UITableViewController
@property (nonatomic, strong) AUOwnRow *row;
@end

@implementation AUOwnChoicePage
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.row.choices.count;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = self.row.choices[(NSUInteger)path.row];
    cell.contentConfiguration = content;
    cell.accessoryType = path.row == AUInteger(self.row.key, self.row.fallback) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:NO];
    [NSUserDefaults.standardUserDefaults setInteger:path.row forKey:self.row.key];
    if (self.row.chosen) self.row.chosen(path.row);
    [table reloadData];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - a slider

@interface AUOwnSliderCell : UITableViewCell
@property (nonatomic, strong) AUOwnRow *row;
@property (nonatomic, strong) UILabel *titleLabel, *valueLabel, *subtitleLabel;
@property (nonatomic, strong) UISlider *slider;
@end

@implementation AUOwnSliderCell
- (instancetype)initWithRow:(AUOwnRow *)row {
    if (!(self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil])) return nil;
    _row = row;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _titleLabel.text = row.title;
    _titleLabel.numberOfLines = 0;
    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize weight:UIFontWeightRegular];
    _valueLabel.textColor = UIColor.secondaryLabelColor;
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _subtitleLabel = [UILabel new];
    _subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _subtitleLabel.textColor = UIColor.secondaryLabelColor;
    _subtitleLabel.numberOfLines = 0;
    _subtitleLabel.text = row.subtitle;
    _subtitleLabel.hidden = !row.subtitle.length;
    _slider = [UISlider new];
    _slider.minimumValue = (float)row.minimum;
    _slider.maximumValue = (float)row.maximum;
    [_slider addTarget:self action:@selector(slid) forControlEvents:UIControlEventValueChanged];
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _valueLabel]];
    top.spacing = 8;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, _subtitleLabel, _slider]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
    [self reload];
    return self;
}

- (void)reload {
    double value = self.row.number ? self.row.number() : self.row.minimum;
    self.slider.value = (float)value;
    self.valueLabel.text = self.row.format ? self.row.format(value) : [NSString stringWithFormat:@"%.2f", value];
    BOOL waiting = rowWaiting(self.row);
    self.slider.enabled = !waiting;
    self.contentView.alpha = waiting ? 0.4 : 1;
}

- (void)slid {
    double value = self.slider.value;
    if (self.row.step > 0) value = self.row.minimum + round((value - self.row.minimum) / self.row.step) * self.row.step;
    value = MAX(self.row.minimum, MIN(self.row.maximum, value));
    if (self.row.setNumber) self.row.setNumber(value);
    self.valueLabel.text = self.row.format ? self.row.format(value) : [NSString stringWithFormat:@"%.2f", value];
}
@end

#pragma mark - the page

@implementation AUOwnPage {
    NSArray<AUOwnSection *> *_sections;
    NSString *_intro, *_footer;
    NSMutableSet<NSNotificationName> *_refreshOn;
}

- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<AUOwnSection *> *)sections footer:(NSString *)footer {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _intro = [intro copy];
    _footer = [footer copy];
    NSMutableArray *kept = [NSMutableArray array];
    for (id section in sections) {
        if ([section isKindOfClass:AUOwnSection.class] && [(AUOwnSection *)section rows].count) [kept addObject:section];
    }
    _sections = kept;
    _refreshOn = [NSMutableSet set];
    for (AUOwnSection *section in _sections) {
        for (AUOwnRow *row in section.rows) {
            if (row.refreshOn) [_refreshOn addObject:row.refreshOn];
        }
    }
    [_refreshOn addObject:AUSettingsDidChangeNotification];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    self.tableView.tableHeaderView = [self noteView:_intro];
    self.tableView.tableFooterView = [self noteView:_footer];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (NSNotificationName name in _refreshOn) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:name object:nil];
    }
    [self.tableView reloadData];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (UIView *note in @[self.tableView.tableHeaderView ?: NSNull.null, self.tableView.tableFooterView ?: NSNull.null]) {
        if (![note isKindOfClass:UIView.class]) continue;
        UILabel *label = note.subviews.firstObject;
        CGFloat width = self.tableView.bounds.size.width;
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 40, CGFLOAT_MAX)];
        CGRect frame = CGRectMake(0, 0, width, ceil(fit.height) + 28);
        if (!CGRectEqualToRect(note.frame, frame)) {
            note.frame = frame;
            label.frame = CGRectMake(20, 14, width - 40, ceil(fit.height));
            if (note == self.tableView.tableHeaderView) self.tableView.tableHeaderView = note;
            else self.tableView.tableFooterView = note;
        }
    }
}

- (UIView *)noteView:(NSString *)text {
    if (!text.length) return nil;
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 40)];
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    [view addSubview:label];
    return view;
}

- (void)refresh {
    // Sliders being dragged are left alone; everything else shows its value now.
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:AUOwnSliderCell.class] && ((AUOwnSliderCell *)cell).slider.isTracking) return;
    }
    [self.tableView reloadData];
}

- (AUOwnRow *)rowAt:(NSIndexPath *)path {
    return _sections[(NSUInteger)path.section].rows[(NSUInteger)path.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_sections[(NSUInteger)section].rows.count;
}

- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section {
    return _sections[(NSUInteger)section].title;
}

- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return _sections[(NSUInteger)section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    AUOwnRow *row = [self rowAt:path];
    if (row.kind == AUOwnRowSlider) return [[AUOwnSliderCell alloc] initWithRow:row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = row.title;
    content.secondaryText = nil;
    content.prefersSideBySideTextAndSecondaryText = YES;
    NSString *value = nil;
    if (row.kind == AUOwnRowChoice) value = choiceValue(row);
    else if (row.value) value = row.value();
    if (row.subtitle.length) {
        // The subtitle under the title, the value on the right.
        content = [UIListContentConfiguration subtitleCellConfiguration];
        content.text = row.title;
        content.secondaryText = row.subtitle;
        content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        content.secondaryTextProperties.numberOfLines = 0;
    } else if (value.length) {
        content.secondaryText = value;
    }
    if (row.color) {
        content.textProperties.color = row.color;
        content.secondaryTextProperties.color = [row.color colorWithAlphaComponent:0.8];
    }
    if (row.symbol.length) {
        content.image = [UIImage systemImageNamed:row.symbol];
        content.imageProperties.tintColor = row.color ?: self.view.tintColor;
    }
    cell.contentConfiguration = content;
    BOOL waiting = rowWaiting(row);
    cell.userInteractionEnabled = !waiting;
    cell.contentView.alpha = waiting ? 0.4 : 1;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    switch (row.kind) {
        case AUOwnRowSwitch:
        case AUOwnRowOption: {
            UISwitch *toggle = [UISwitch new];
            toggle.on = switchOn(row);
            toggle.enabled = !waiting;
            objc_setAssociatedObject(toggle, @selector(toggled:), row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case AUOwnRowPage:
        case AUOwnRowChoice:
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (row.subtitle.length && value.length) cell.accessoryView = [self valueLabel:value disclosure:YES];
            break;
        case AUOwnRowAction:
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (row.subtitle.length && value.length) cell.accessoryView = [self valueLabel:value disclosure:NO];
            break;
        case AUOwnRowStat:
            if (row.subtitle.length && value.length) cell.accessoryView = [self valueLabel:value disclosure:NO];
            break;
        case AUOwnRowSlider:
            break;
    }
    return cell;
}

- (UIView *)valueLabel:(NSString *)text disclosure:(BOOL)disclosure {
    UILabel *label = [UILabel new];
    label.text = disclosure ? [text stringByAppendingString:@"  ›"] : text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentRight;
    [label sizeToFit];
    CGRect frame = label.frame;
    frame.size.width = MIN(frame.size.width, 160);
    label.frame = frame;
    return label;
}

- (void)toggled:(UISwitch *)toggle {
    AUOwnRow *row = objc_getAssociatedObject(toggle, @selector(toggled:));
    if (!row.key) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:row.key];
    if (row.changed) row.changed(toggle.on);
    else AUSettingsChanged();
    dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; });
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    AUOwnRow *row = [self rowAt:path];
    if (rowWaiting(row)) return;
    switch (row.kind) {
        case AUOwnRowPage: {
            UIViewController *page = row.page ? row.page() : nil;
            if (page) [self.navigationController pushViewController:page animated:YES];
            break;
        }
        case AUOwnRowChoice: {
            AUOwnChoicePage *page = [[AUOwnChoicePage alloc] initWithStyle:UITableViewStyleInsetGrouped];
            page.title = row.title;
            page.row = row;
            [self.navigationController pushViewController:page animated:YES];
            break;
        }
        case AUOwnRowAction: {
            if (row.action) row.action();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [table reloadData]; });
            break;
        }
        default:
            break;
    }
}

@end
