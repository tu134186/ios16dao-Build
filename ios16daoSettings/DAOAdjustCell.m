// 滑块 + 减号 + 加号 + 数值：原版「动画透明度 / 比例 / 光圈粗细 / 偏移 / 清晰度」都用这一种 cell。
#import "DAOAdjustCell.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static NSString *const kDAODomain = @"com.minis.ios16dao";
static CFStringRef const kDAONotify = CFSTR("com.minis.ios16dao/changed");

@interface DAOAdjustCell ()
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIButton *minusButton;
@property (nonatomic, strong) UIButton *plusButton;
@property (nonatomic, assign) float step;
@end

@implementation DAOAdjustCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:UITableViewCellStyleDefault
                    reuseIdentifier:reuseIdentifier
                          specifier:specifier])) {
        _slider = [UISlider new];
        _valueLabel = [UILabel new];
        _minusButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _plusButton = [UIButton buttonWithType:UIButtonTypeSystem];

        [_minusButton setTitle:@"−" forState:UIControlStateNormal];
        [_plusButton setTitle:@"+" forState:UIControlStateNormal];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        _valueLabel.adjustsFontSizeToFitWidth = YES;
        _valueLabel.textColor = [UIColor secondaryLabelColor];

        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_minusButton addTarget:self action:@selector(stepDown) forControlEvents:UIControlEventTouchUpInside];
        [_plusButton addTarget:self action:@selector(stepUp) forControlEvents:UIControlEventTouchUpInside];

        for (UIView *v in @[_slider, _valueLabel, _minusButton, _plusButton])
            [self.contentView addSubview:v];

        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self reload];
}

- (float)storedValue {
    NSString *key = [self.specifier propertyForKey:@"key"];
    CFPropertyListRef stored = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                         (__bridge CFStringRef)kDAODomain);
    float v = stored ? [(__bridge id)stored floatValue]
                     : [[self.specifier propertyForKey:@"default"] floatValue];
    if (stored) CFRelease(stored);
    return v;
}

- (void)reload {
    self.textLabel.text = self.specifier.name;
    self.textLabel.adjustsFontSizeToFitWidth = YES;
    self.slider.minimumValue = [[self.specifier propertyForKey:@"min"] floatValue];
    self.slider.maximumValue = [[self.specifier propertyForKey:@"max"] floatValue];
    self.step = [[self.specifier propertyForKey:@"step"] floatValue];
    if (self.step <= 0) self.step = 0.1f;

    float v = [self storedValue];
    v = fmaxf(self.slider.minimumValue, fminf(self.slider.maximumValue, v));
    self.slider.value = v;
    [self showValue];
}

- (void)showValue {
    NSString *fmt = [self.specifier propertyForKey:@"format"];
    if (![fmt isKindOfClass:[NSString class]]) {
        CGFloat mx = self.slider.maximumValue;
        fmt = mx <= 1.0 ? @"%.0f%%" : (mx <= 2.0 ? @"%.2fx" : @"%.0f");
    }
    float v = self.slider.value;
    if ([fmt containsString:@"%%"]) {
        self.valueLabel.text = [NSString stringWithFormat:fmt, v * 100.0];
    } else {
        NSString *unit = [self.specifier propertyForKey:@"unit"];
        self.valueLabel.text = [NSString stringWithFormat:fmt, v];
        if ([unit isKindOfClass:[NSString class]] && unit.length)
            self.valueLabel.text = [self.valueLabel.text stringByAppendingString:unit];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat pad = 16.0, labelW = 96.0, btnW = 30.0, valueW = 54.0;

    self.textLabel.frame = CGRectMake(pad, 0, labelW, h);
    self.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];

    CGFloat valueX = w - pad - valueW;
    CGFloat plusX = valueX - 2.0 - btnW;
    CGFloat minusX = pad + labelW;
    CGFloat sliderX = minusX + btnW + 2.0;
    CGFloat sliderEnd = plusX - 6.0;

    self.minusButton.frame = CGRectMake(minusX, 0, btnW, h);
    self.slider.frame = CGRectMake(sliderX, (h - 30.0) / 2.0, MAX(40.0, sliderEnd - sliderX), 30.0);
    self.plusButton.frame = CGRectMake(plusX, 0, btnW, h);
    self.valueLabel.frame = CGRectMake(valueX, 0, valueW, h);

    UIFont *btnFont = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
    self.minusButton.titleLabel.font = btnFont;
    self.plusButton.titleLabel.font = btnFont;
}

- (void)save {
    NSString *key = [self.specifier propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)@(self.slider.value),
                             (__bridge CFStringRef)kDAODomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDAODomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kDAONotify, NULL, NULL, YES);
    [self showValue];
}

- (void)sliderChanged:(UISlider *)slider {
    (void)slider;
    [self save];
}

- (void)stepDown { [self applyDelta:-self.step]; }
- (void)stepUp   { [self applyDelta:self.step]; }

- (void)applyDelta:(float)delta {
    float v = self.slider.value + delta;
    v = roundf(v / self.step) * self.step;
    self.slider.value = fmaxf(self.slider.minimumValue, fminf(self.slider.maximumValue, v));
    [self save];
}

@end