//
//  CJLabel.m
//  CJLabelTest
//
//  Created by ChiJinLian on 17/3/31.
//  Copyright © 2017年 ChiJinLian. All rights reserved.
//

#import "CJLabel.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>


NSString * const kCJBackgroundFillColorAttributeName         = @"kCJBackgroundFillColor";
NSString * const kCJBackgroundStrokeColorAttributeName       = @"kCJBackgroundStrokeColor";
NSString * const kCJBackgroundLineWidthAttributeName         = @"kCJBackgroundLineWidth";
NSString * const kCJBackgroundLineCornerRadiusAttributeName  = @"kCJBackgroundLineCornerRadius";
NSString * const kCJActiveBackgroundFillColorAttributeName   = @"kCJActiveBackgroundFillColor";
NSString * const kCJActiveBackgroundStrokeColorAttributeName = @"kCJActiveBackgroundStrokeColor";


static CGFloat const CJFLOAT_MAX = 100000;



static inline CGFLOAT_TYPE CGFloat_ceil(CGFLOAT_TYPE cgfloat) {
#if CGFLOAT_IS_DOUBLE
    return ceil(cgfloat);
#else
    return ceilf(cgfloat);
#endif
}

static inline CGFLOAT_TYPE CGFloat_floor(CGFLOAT_TYPE cgfloat) {
#if CGFLOAT_IS_DOUBLE
    return floor(cgfloat);
#else
    return floorf(cgfloat);
#endif
}

static inline CGFloat CJFlushFactorForTextAlignment(NSTextAlignment textAlignment) {
    switch (textAlignment) {
        case NSTextAlignmentCenter:
            return 0.5f;
        case NSTextAlignmentRight:
            return 1.0f;
        case NSTextAlignmentLeft:
        default:
            return 0.0f;
    }
}


static inline CGColorRef CGColorRefFromColor(id color) {
    return [color isKindOfClass:[UIColor class]] ? [color CGColor] : (__bridge CGColorRef)color;
}

static inline NSAttributedString * NSAttributedStringByScalingFontSize(NSAttributedString *attributedString, CGFloat scale) {
    NSMutableAttributedString *mutableAttributedString = [attributedString mutableCopy];
    [mutableAttributedString enumerateAttribute:(NSString *)kCTFontAttributeName inRange:NSMakeRange(0, [mutableAttributedString length]) options:0 usingBlock:^(id value, NSRange range, BOOL * __unused stop) {
        UIFont *font = (UIFont *)value;
        if (font) {
            NSString *fontName;
            CGFloat pointSize;
            
            if ([font isKindOfClass:[UIFont class]]) {
                fontName = font.fontName;
                pointSize = font.pointSize;
            } else {
                fontName = (NSString *)CFBridgingRelease(CTFontCopyName((__bridge CTFontRef)font, kCTFontPostScriptNameKey));
                pointSize = CTFontGetSize((__bridge CTFontRef)font);
            }
            
            [mutableAttributedString removeAttribute:(NSString *)kCTFontAttributeName range:range];
            CTFontRef fontRef = CTFontCreateWithName((__bridge CFStringRef)fontName, CGFloat_floor(pointSize * scale), NULL);
            [mutableAttributedString addAttribute:(NSString *)kCTFontAttributeName value:(__bridge id)fontRef range:range];
            CFRelease(fontRef);
        }
    }];
    
    return mutableAttributedString;
}

static inline CGSize CTFramesetterSuggestFrameSizeForAttributedStringWithConstraints(CTFramesetterRef framesetter, NSAttributedString *attributedString, CGSize size, NSUInteger numberOfLines) {
    CFRange rangeToSize = CFRangeMake(0, (CFIndex)[attributedString length]);
    CGSize constraints = CGSizeMake(size.width, CJFLOAT_MAX);
    
    if (numberOfLines == 1) {
        constraints = CGSizeMake(CJFLOAT_MAX, CJFLOAT_MAX);
    } else if (numberOfLines > 0) {
        CGMutablePathRef path = CGPathCreateMutable();
        CGPathAddRect(path, NULL, CGRectMake(0.0f, 0.0f, constraints.width, CJFLOAT_MAX));
        CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, NULL);
        CFArrayRef lines = CTFrameGetLines(frame);
        
        if (CFArrayGetCount(lines) > 0) {
            NSInteger lastVisibleLineIndex = MIN((CFIndex)numberOfLines, CFArrayGetCount(lines)) - 1;
            CTLineRef lastVisibleLine = CFArrayGetValueAtIndex(lines, lastVisibleLineIndex);
            
            CFRange rangeToLayout = CTLineGetStringRange(lastVisibleLine);
            rangeToSize = CFRangeMake(0, rangeToLayout.location + rangeToLayout.length);
        }
        
        CFRelease(frame);
        CGPathRelease(path);
    }
    
    CGSize suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, rangeToSize, NULL, constraints, NULL);
    
    return CGSizeMake(CGFloat_ceil(suggestedSize.width), CGFloat_ceil(suggestedSize.height));
};

static inline CGFloat compareMaxNum(CGFloat firstNum, CGFloat secondNum, BOOL max){
    CGFloat result = firstNum;
    if (max) {
        result = (firstNum >= secondNum)?firstNum:secondNum;
    }else{
        result = (firstNum <= secondNum)?firstNum:secondNum;
    }
    return result;
}

static inline UIColor * colorWithAttributeName(NSDictionary *dic, NSString *key){
    UIColor *color = [UIColor clearColor];
    if (dic[key] && nil != dic[key]) {
        color = dic[key];
    }
    return color;
}

static inline BOOL isNotClearColor(UIColor *color){
    BOOL notClearColor = YES;
    if (CGColorEqualToColor(color.CGColor, [UIColor clearColor].CGColor)) {
        notClearColor = NO;
    }
    return notClearColor;
}

static inline BOOL isSameColor(UIColor *color1, UIColor *color2){
    BOOL same = YES;
    if (!CGColorEqualToColor(color1.CGColor, color2.CGColor)) {
        same = NO;
    }
    return same;
}



@interface CJLabel ()<UIGestureRecognizerDelegate>

//当前显示的AttributedText
@property (readwrite, nonatomic, copy) NSAttributedString *renderedAttributedText;
@property (nonatomic, strong, readonly) UILongPressGestureRecognizer *longPressGestureRecognizer;
@end

@implementation CJLabel {
@private
    BOOL _needsFramesetter;
    CTFramesetterRef _framesetter;
    CTFramesetterRef _highlightFramesetter;
    CGFloat _yOffset;
    BOOL _longPress;//判断是否长按;
    BOOL _needRedrawn;//是否需要重新计算_runStrokeItemArray以及_linkStrokeItemArray数组
    NSArray <CJGlyphRunStrokeItem *>*_runStrokeItemArray;//所有需要重绘背景或边框线的StrokeItem数组
    NSArray <CJGlyphRunStrokeItem *>*_linkStrokeItemArray;//可点击链点的StrokeItem数组
    CJGlyphRunStrokeItem *_lastGlyphRunStrokeItem;//计算StrokeItem的中间变量
    CJGlyphRunStrokeItem *_currentClickRunStrokeItem;//当前点击选中的StrokeItem
}


@synthesize text = _text;
@synthesize attributedText = _attributedText;

#if !TARGET_OS_TV
#pragma mark - UIResponderStandardEditActions

- (void)copy:(__unused id)sender {
    [[UIPasteboard generalPasteboard] setString:self.attributedText.string];
}
#endif

- (id)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    self.userInteractionEnabled = YES;
    self.textInsets = UIEdgeInsetsZero;
    self.verticalAlignment = CJContentVerticalAlignmentCenter;
    _needRedrawn = NO;
    _longPress = NO;
    _extendsLinkTouchArea = NO;
    _lastGlyphRunStrokeItem = nil;
    _linkStrokeItemArray = nil;
    _runStrokeItemArray = nil;
    _currentClickRunStrokeItem = nil;
    _longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(longPressGestureDidFire:)];
    self.longPressGestureRecognizer.delegate = self;
    [self addGestureRecognizer:self.longPressGestureRecognizer];
}

- (void)dealloc {
    if (_framesetter) {
        CFRelease(_framesetter);
    }
    
    if (_highlightFramesetter) {
        CFRelease(_highlightFramesetter);
    }
    
    if (_longPressGestureRecognizer) {
        [self removeGestureRecognizer:_longPressGestureRecognizer];
    }
}

- (void)setText:(id)text {
    NSParameterAssert(!text || [text isKindOfClass:[NSAttributedString class]] || [text isKindOfClass:[NSString class]]);
    
    NSMutableAttributedString *mutableAttributedString = nil;
    if ([text isKindOfClass:[NSString class]]) {
        NSMutableDictionary *mutableAttributes = [NSMutableDictionary dictionary];
        [mutableAttributes setObject:self.font forKey:(NSString *)kCTFontAttributeName];
        [mutableAttributes setObject:self.textColor forKey:(NSString *)kCTForegroundColorAttributeName];
        
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.alignment = self.textAlignment;
        if (self.numberOfLines == 1) {
            paragraphStyle.lineBreakMode = self.lineBreakMode;
        } else {
            paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
        }
        [mutableAttributes setObject:paragraphStyle forKey:(NSString *)kCTParagraphStyleAttributeName];
        mutableAttributedString = [[NSMutableAttributedString alloc] initWithString:text attributes:mutableAttributes];
    }else{
        mutableAttributedString = text;
    }
    self.attributedText = mutableAttributedString;
}

- (void)setAttributedText:(NSAttributedString *)text {
    if ([text isEqualToAttributedString:_attributedText]) {
        return;
    }
    
    _longPress = NO;
    _needRedrawn = NO;
    _runStrokeItemArray = nil;
    _linkStrokeItemArray = nil;
    _currentClickRunStrokeItem = nil;
    
    //获取点击链点的NSRange
    NSMutableAttributedString *attText = [[NSMutableAttributedString alloc]initWithAttributedString:text];

    [attText enumerateAttributesInRange:NSMakeRange(0, text.length) options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired usingBlock:^(NSDictionary<NSString *, id> *attrs, NSRange range, BOOL *stop){
        BOOL isLink = [attrs[kCJIsLinkAttributesName] boolValue];
        if (isLink) {
            [attText addAttribute:kCJLinkRangeAttributesName value:NSStringFromRange(range) range:range];
        }else{
            [attText removeAttribute:kCJLinkRangeAttributesName range:range];
        }
    }];
    
    _attributedText = [attText copy];
    
    [self setNeedsFramesetter];
    [self setNeedsDisplay];
    
    if ([self respondsToSelector:@selector(invalidateIntrinsicContentSize)]) {
        [self invalidateIntrinsicContentSize];
    }
    
    [super setText:[self.attributedText string]];
}

- (NSAttributedString *)renderedAttributedText {
    if (!_renderedAttributedText) {
        NSMutableAttributedString *fullString = [[NSMutableAttributedString alloc] initWithAttributedString:self.attributedText];
        
        [fullString enumerateAttributesInRange:NSMakeRange(0, fullString.length) options:NSAttributedStringEnumerationLongestEffectiveRangeNotRequired usingBlock:^(NSDictionary<NSString *, id> *attrs, NSRange range, BOOL *stop){
            
            NSDictionary *linkAttributes = attrs[kCJLinkAttributesName];
            if (!CJLabelIsNull(linkAttributes)) {
                [fullString addAttributes:linkAttributes range:range];
            }
            
            NSDictionary *activeLinkAttributes = attrs[kCJActiveLinkAttributesName];
            if (!CJLabelIsNull(activeLinkAttributes)) {
                //设置当前点击链点的activeLinkAttributes属性
                if (_currentClickRunStrokeItem && NSEqualRanges(_currentClickRunStrokeItem.range,range)) {
                    [fullString addAttributes:activeLinkAttributes range:range];
                }else{
                    for (NSString *key in activeLinkAttributes) {
                        [fullString removeAttribute:key range:range];
                    }
                    //防止将linkAttributes中的属性也删除了
                    if (!CJLabelIsNull(linkAttributes)) {
                        [fullString addAttributes:linkAttributes range:range];
                    }
                }
            }
        }];
        
        NSAttributedString *string = [[NSAttributedString alloc] initWithAttributedString:fullString];
        self.renderedAttributedText = string;
    }
    
    return _renderedAttributedText;
}

- (void)setNeedsFramesetter {
    self.renderedAttributedText = nil;
    _needsFramesetter = YES;
    
}

- (CTFramesetterRef)framesetter {
    if (_needsFramesetter) {
        @synchronized(self) {
            CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)self.renderedAttributedText);
            [self setFramesetter:framesetter];
            [self setHighlightFramesetter:nil];
            _needsFramesetter = NO;
            
            if (framesetter) {
                CFRelease(framesetter);
            }
        }
    }
    
    return _framesetter;
}

- (void)setFramesetter:(CTFramesetterRef)framesetter {
    if (framesetter) {
        CFRetain(framesetter);
    }
    
    if (_framesetter) {
        CFRelease(_framesetter);
    }
    
    _framesetter = framesetter;
}

- (CTFramesetterRef)highlightFramesetter {
    return _highlightFramesetter;
}

- (void)setHighlightFramesetter:(CTFramesetterRef)highlightFramesetter {
    if (highlightFramesetter) {
        CFRetain(highlightFramesetter);
    }
    
    if (_highlightFramesetter) {
        CFRelease(_highlightFramesetter);
    }
    
    _highlightFramesetter = highlightFramesetter;
}

#pragma mark - Public method
+ (CGSize)getStringRect:(NSAttributedString *)aString width:(CGFloat)width height:(CGFloat)height {
    CGSize size = CGSizeZero;
    NSMutableAttributedString *atrString = [[NSMutableAttributedString alloc] initWithAttributedString:aString];
    NSRange range = NSMakeRange(0, atrString.length);
    
    //获取指定位置上的属性信息，并返回与指定位置属性相同并且连续的字符串的范围信息。
    NSDictionary* dic = [atrString attributesAtIndex:0 effectiveRange:&range];
    //不存在段落属性，则存入默认值
    NSMutableParagraphStyle *paragraphStyle = dic[NSParagraphStyleAttributeName];
    if (!paragraphStyle || nil == paragraphStyle) {
        paragraphStyle = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
        paragraphStyle.lineSpacing = 0.0;//增加行高
        paragraphStyle.headIndent = 0;//头部缩进，相当于左padding
        paragraphStyle.tailIndent = 0;//相当于右padding
        paragraphStyle.lineHeightMultiple = 0;//行间距是多少倍
        paragraphStyle.alignment = NSTextAlignmentLeft;//对齐方式
        paragraphStyle.firstLineHeadIndent = 0;//首行头缩进
        paragraphStyle.paragraphSpacing = 0;//段落后面的间距
        paragraphStyle.paragraphSpacingBefore = 0;//段落之前的间距
        [atrString addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:range];
    }
    
    NSMutableDictionary *attDic = [NSMutableDictionary dictionaryWithDictionary:dic];
    [attDic setObject:paragraphStyle forKey:NSParagraphStyleAttributeName];
    
    CGSize strSize = [[aString string] boundingRectWithSize:CGSizeMake(width, height)
                                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                 attributes:attDic
                                                    context:nil].size;
    
    size = CGSizeMake(CGFloat_ceil(strSize.width), CGFloat_ceil(strSize.height));
//    NSLog(@"boundingRectWithSize %@",NSStringFromCGSize(size));
    return size;
}

- (NSMutableAttributedString *)configureAttributedString:(NSAttributedString *)attrStr
                                            addImageName:(NSString *)imageName
                                               imageSize:(CGSize)size
                                                 atIndex:(NSUInteger)loc
                                              attributes:(NSDictionary *)attributes
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr addImageName:imageName imageSize:size atIndex:loc linkAttributes:attributes activeLinkAttributes:nil parameter:nil clickLinkBlock:nil longPressBlock:nil islink:NO];
}

- (NSMutableAttributedString *)configureLinkAttributedString:(NSAttributedString *)attrStr
                                                addImageName:(NSString *)imageName
                                                   imageSize:(CGSize)size
                                                     atIndex:(NSUInteger)loc
                                              linkAttributes:(NSDictionary *)linkAttributes
                                        activeLinkAttributes:(NSDictionary *)activeLinkAttributes
                                                   parameter:(id)parameter
                                              clickLinkBlock:(CJLabelLinkModelBlock)clickLinkBlock
                                              longPressBlock:(CJLabelLinkModelBlock)longPressBlock
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr addImageName:imageName imageSize:size atIndex:loc linkAttributes:linkAttributes activeLinkAttributes:activeLinkAttributes parameter:parameter clickLinkBlock:clickLinkBlock longPressBlock:longPressBlock islink:YES];
}

- (NSMutableAttributedString *)configureAttributedString:(NSAttributedString *)attrStr
                                                 atRange:(NSRange)range
                                              attributes:(NSDictionary *)attributes
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr atRange:range linkAttributes:attributes activeLinkAttributes:nil parameter:nil clickLinkBlock:nil longPressBlock:nil islink:NO];
}

- (NSMutableAttributedString *)configureLinkAttributedString:(NSAttributedString *)attrStr
                                                     atRange:(NSRange)range
                                              linkAttributes:(NSDictionary *)linkAttributes
                                        activeLinkAttributes:(NSDictionary *)activeLinkAttributes
                                                   parameter:(id)parameter
                                              clickLinkBlock:(CJLabelLinkModelBlock)clickLinkBlock
                                              longPressBlock:(CJLabelLinkModelBlock)longPressBlock
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr atRange:range linkAttributes:linkAttributes activeLinkAttributes:activeLinkAttributes parameter:parameter clickLinkBlock:clickLinkBlock longPressBlock:longPressBlock islink:YES];
}

- (NSMutableAttributedString *)configureAttributedString:(NSAttributedString *)attrStr
                                           withAttString:(NSAttributedString *)withAttString
                                        sameStringEnable:(BOOL)sameStringEnable
                                              attributes:(NSDictionary *)attributes
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr withAttString:withAttString sameStringEnable:sameStringEnable linkAttributes:attributes activeLinkAttributes:nil parameter:nil clickLinkBlock:nil longPressBlock:nil islink:NO];
}

- (NSMutableAttributedString *)configureLinkAttributedString:(NSAttributedString *)attrStr
                                               withAttString:(NSAttributedString *)withAttString
                                            sameStringEnable:(BOOL)sameStringEnable
                                              linkAttributes:(NSDictionary *)linkAttributes
                                        activeLinkAttributes:(NSDictionary *)activeLinkAttributes
                                                   parameter:(id)parameter
                                              clickLinkBlock:(CJLabelLinkModelBlock)clickLinkBlock
                                              longPressBlock:(CJLabelLinkModelBlock)longPressBlock
{
    return [CJLabelUtilities configureLinkAttributedString:attrStr withAttString:withAttString sameStringEnable:sameStringEnable linkAttributes:linkAttributes activeLinkAttributes:activeLinkAttributes parameter:parameter clickLinkBlock:clickLinkBlock longPressBlock:longPressBlock islink:YES];
}


#pragma mark - UILabel

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self setNeedsDisplay];
}

- (UIColor *)textColor {
    UIColor *color = [super textColor];
    if (!color) {
        color = [UIColor blackColor];
    }
    return color;
}

- (void)setTextColor:(UIColor *)textColor {
    UIColor *oldTextColor = self.textColor;
    [super setTextColor:textColor];
    if (textColor != oldTextColor) {
        [self setNeedsFramesetter];
        [self setNeedsDisplay];
    }
}

- (CGRect)textRectForBounds:(CGRect)bounds
     limitedToNumberOfLines:(NSInteger)numberOfLines
{
    bounds = UIEdgeInsetsInsetRect(bounds, self.textInsets);
    if (!self.attributedText) {
        return [super textRectForBounds:bounds limitedToNumberOfLines:numberOfLines];
    }
    
    CGRect textRect = bounds;
    
    // 确保高度至少为字体lineHeight的两倍，以确保当textRect高度不足时，CTFramesetterSuggestFrameSizeWithConstraints不返回CGSizeZero。
    textRect.size.height = MAX(self.font.lineHeight * MAX(2, numberOfLines), bounds.size.height);
    
    // 垂直方向的对齐方式
    CGSize textSize = CTFramesetterSuggestFrameSizeWithConstraints([self framesetter], CFRangeMake(0, (CFIndex)[self.attributedText length]), NULL, textRect.size, NULL);
    textSize = CGSizeMake(CGFloat_ceil(textSize.width), CGFloat_ceil(textSize.height)); // Fix for iOS 4, CTFramesetterSuggestFrameSizeWithConstraints sometimes returns fractional sizes
    
    if (textSize.height < bounds.size.height) {
         _yOffset = 0.0f;
        switch (self.verticalAlignment) {
            case CJContentVerticalAlignmentCenter:
                _yOffset = CGFloat_floor((bounds.size.height - textSize.height) / 2.0f);
                break;
            case CJContentVerticalAlignmentBottom:
                _yOffset = bounds.size.height - textSize.height;
                break;
            case CJContentVerticalAlignmentTop:
            default:
                break;
        }
        textRect.origin.y += _yOffset;
    }
    
    return textRect;
}

- (void)drawTextInRect:(CGRect)rect {
    CGRect insetRect = UIEdgeInsetsInsetRect(rect, self.textInsets);
    if (!self.attributedText) {
        [super drawTextInRect:insetRect];
        return;
    }
    
    NSAttributedString *originalAttributedText = nil;
    
    // 根据font size调整宽度
    if (self.adjustsFontSizeToFitWidth && self.numberOfLines > 0) {
        [self setNeedsFramesetter];
        [self setNeedsDisplay];
        
        if ([self respondsToSelector:@selector(invalidateIntrinsicContentSize)]) {
            [self invalidateIntrinsicContentSize];
        }
        
        //设置最大size
        CGSize maxSize = (self.numberOfLines > 1) ? CGSizeMake(CJFLOAT_MAX, CJFLOAT_MAX) : CGSizeZero;
        
        CGFloat textWidth = [self sizeThatFits:maxSize].width;
        CGFloat availableWidth = self.frame.size.width * self.numberOfLines;
        if (self.numberOfLines > 1 && self.lineBreakMode == NSLineBreakByWordWrapping) {
            textWidth *= (M_PI / M_E);
        }
        
        if (textWidth > availableWidth && textWidth > 0.0f) {
            originalAttributedText = [self.attributedText copy];
            
            CGFloat scaleFactor = availableWidth / textWidth;
            if ([self respondsToSelector:@selector(minimumScaleFactor)] && self.minimumScaleFactor > scaleFactor) {
                scaleFactor = self.minimumScaleFactor;
            }
            self.attributedText = NSAttributedStringByScalingFontSize(self.attributedText, scaleFactor);
        }
    }
    
    CGContextRef c = UIGraphicsGetCurrentContext();
    // 先将当前图形状态推入堆栈
    CGContextSaveGState(c);
    {
        // 设置字形变换矩阵为CGAffineTransformIdentity，也就是说每一个字形都不做图形变换
        CGContextSetTextMatrix(c, CGAffineTransformIdentity);
        
        // 坐标转换，iOS 坐标原点在左上角，Mac OS 坐标原点在左下角
        CGContextTranslateCTM(c, 0.0f, insetRect.size.height);
        CGContextScaleCTM(c, 1.0f, -1.0f);
        
        CFRange textRange = CFRangeMake(0, (CFIndex)[self.attributedText length]);
        
        // 获取textRect
        CGRect textRect = [self textRectForBounds:rect limitedToNumberOfLines:self.numberOfLines];
        // CTM 坐标移到左下角
        CGContextTranslateCTM(c, insetRect.origin.x, insetRect.size.height - textRect.origin.y - textRect.size.height);
        
        // 处理阴影 shadowColor
        if (self.shadowColor && !self.highlighted) {
            CGContextSetShadowWithColor(c, self.shadowOffset, self.shadowRadius, [self.shadowColor CGColor]);
        }
        
        if (self.highlightedTextColor && self.highlighted) {
            NSMutableAttributedString *highlightAttributedString = [self.renderedAttributedText mutableCopy];
            [highlightAttributedString addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName value:(id)[self.highlightedTextColor CGColor] range:NSMakeRange(0, highlightAttributedString.length)];
            
            if (![self highlightFramesetter]) {
                CTFramesetterRef highlightFramesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)highlightAttributedString);
                [self setHighlightFramesetter:highlightFramesetter];
                CFRelease(highlightFramesetter);
            }
            
            [self drawFramesetter:[self highlightFramesetter] attributedString:highlightAttributedString textRange:textRange inRect:textRect context:c];
        } else {
            [self drawFramesetter:[self framesetter] attributedString:self.renderedAttributedText textRange:textRange inRect:textRect context:c];
        }
        
        // 判断是否调整了size，如果是，则还原 attributedText
        if (originalAttributedText) {
            _attributedText = originalAttributedText;
        }
    }
    CGContextRestoreGState(c);
}

#pragma mark - 绘制
- (void)drawFramesetter:(CTFramesetterRef)framesetter
       attributedString:(NSAttributedString *)attributedString
              textRange:(CFRange)textRange
                 inRect:(CGRect)rect
                context:(CGContextRef)c
{
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, rect);
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter, textRange, path, NULL);
    
    if (_needRedrawn) {
        // 获取所有需要重绘背景的StrokeItem数组
        _runStrokeItemArray = [self calculateRunStrokeItemsFrame:frame inRect:rect];
        _linkStrokeItemArray = [self getLinkStrokeItems:_runStrokeItemArray];
    }
    if (!_runStrokeItemArray) {
        // 获取所有需要重绘背景的StrokeItem数组
        _runStrokeItemArray = [self calculateRunStrokeItemsFrame:frame inRect:rect];
        _linkStrokeItemArray = [self getLinkStrokeItems:_runStrokeItemArray];
    }
    [self drawBackgroundColor:c runStrokeItems:_runStrokeItemArray isStrokeColor:NO];
    
    
    CFArrayRef lines = CTFrameGetLines(frame);
    NSInteger numberOfLines = self.numberOfLines > 0 ? MIN(self.numberOfLines, CFArrayGetCount(lines)) : CFArrayGetCount(lines);
    BOOL truncateLastLine = (self.lineBreakMode == NSLineBreakByTruncatingHead || self.lineBreakMode == NSLineBreakByTruncatingMiddle || self.lineBreakMode == NSLineBreakByTruncatingTail);
    
    CGPoint lineOrigins[numberOfLines];
    CTFrameGetLineOrigins(frame, CFRangeMake(0, numberOfLines), lineOrigins);
    
    for (CFIndex lineIndex = 0; lineIndex < numberOfLines; lineIndex++) {
        CGPoint lineOrigin = lineOrigins[lineIndex];
        CGContextSetTextPosition(c, lineOrigin.x, lineOrigin.y);
        CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
        
        CGFloat ascent = 0.0f, descent = 0.0f, leading = 0.0f;
        CTLineGetTypographicBounds((CTLineRef)line, &ascent, &descent, &leading);

        CGFloat y = lineOrigin.y;
        
        // 根据水平对齐方式调整偏移量
        CGFloat flushFactor = CJFlushFactorForTextAlignment(self.textAlignment);
        
        if (lineIndex == numberOfLines - 1 && truncateLastLine) {
            // 判断最后一行是否占满整行
            CFRange lastLineRange = CTLineGetStringRange(line);
            
            if (!(lastLineRange.length == 0 && lastLineRange.location == 0) && lastLineRange.location + lastLineRange.length < textRange.location + textRange.length) {

                CTLineTruncationType truncationType;
                CFIndex truncationAttributePosition = lastLineRange.location;
                NSLineBreakMode lineBreakMode = self.lineBreakMode;
                
                // 多行时lineBreakMode默认为NSLineBreakByTruncatingTail
                if (numberOfLines != 1) {
                    lineBreakMode = NSLineBreakByTruncatingTail;
                }
                
                switch (lineBreakMode) {
                    case NSLineBreakByTruncatingHead:
                        truncationType = kCTLineTruncationStart;
                        break;
                    case NSLineBreakByTruncatingMiddle:
                        truncationType = kCTLineTruncationMiddle;
                        truncationAttributePosition += (lastLineRange.length / 2);
                        break;
                    case NSLineBreakByTruncatingTail:
                    default:
                        truncationType = kCTLineTruncationEnd;
                        truncationAttributePosition += (lastLineRange.length - 1);
                        break;
                }
                
                NSAttributedString *attributedTruncationString = nil;
                if (!attributedTruncationString) {
                    NSString *truncationTokenString = @"\u2026"; // \u2026 对应"..."的Unicode编码
                    
                    NSDictionary *truncationTokenStringAttributes = truncationTokenStringAttributes = [attributedString attributesAtIndex:(NSUInteger)truncationAttributePosition effectiveRange:NULL];
                    
                    attributedTruncationString = [[NSAttributedString alloc] initWithString:truncationTokenString attributes:truncationTokenStringAttributes];
                }
                CTLineRef truncationToken = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributedTruncationString);
                
                // Append truncationToken to the string
                // because if string isn't too long, CT won't add the truncationToken on its own.
                // There is no chance of a double truncationToken because CT only adds the
                // token if it removes characters (and the one we add will go first)
                NSMutableAttributedString *truncationString = [[NSMutableAttributedString alloc] initWithAttributedString:
                                                               [attributedString attributedSubstringFromRange:
                                                                NSMakeRange((NSUInteger)lastLineRange.location,
                                                                            (NSUInteger)lastLineRange.length)]];
                if (lastLineRange.length > 0) {
                    // Remove any newline at the end (we don't want newline space between the text and the truncation token). There can only be one, because the second would be on the next line.
                    unichar lastCharacter = [[truncationString string] characterAtIndex:(NSUInteger)(lastLineRange.length - 1)];
                    if ([[NSCharacterSet newlineCharacterSet] characterIsMember:lastCharacter]) {
                        [truncationString deleteCharactersInRange:NSMakeRange((NSUInteger)(lastLineRange.length - 1), 1)];
                    }
                }
                [truncationString appendAttributedString:attributedTruncationString];
                CTLineRef truncationLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)truncationString);
                
                // Truncate the line in case it is too long.
                CTLineRef truncatedLine = CTLineCreateTruncatedLine(truncationLine, rect.size.width, truncationType, truncationToken);
                if (!truncatedLine) {
                    // If the line is not as wide as the truncationToken, truncatedLine is NULL
                    truncatedLine = CFRetain(truncationToken);
                }
                
                CGFloat penOffset = (CGFloat)CTLineGetPenOffsetForFlush(truncatedLine, flushFactor, rect.size.width);
                CGContextSetTextPosition(c, penOffset, y );
                
                CTLineDraw(truncatedLine, c);
                
                CFRelease(truncatedLine);
                CFRelease(truncationLine);
                CFRelease(truncationToken);
            } else {
                CGFloat penOffset = (CGFloat)CTLineGetPenOffsetForFlush(line, flushFactor, rect.size.width);
                CGContextSetTextPosition(c, penOffset, y );
                CTLineDraw(line, c);
            }
        } else {
            CGFloat penOffset = (CGFloat)CTLineGetPenOffsetForFlush(line, flushFactor, rect.size.width);
            CGContextSetTextPosition(c, penOffset, y );
            CTLineDraw(line, c);
        }
        
        // 绘制插入图片
        [self drawImageLine:line context:c lineOrigins:lineOrigins lineIndex:lineIndex];
    }
    
    // 绘制描边
    [self drawBackgroundColor:c runStrokeItems:_runStrokeItemArray isStrokeColor:YES];
    
    CFRelease(frame);
    CGPathRelease(path);
}

- (void)drawBackgroundColor:(CGContextRef)c
             runStrokeItems:(NSArray <CJGlyphRunStrokeItem *>*)runStrokeItems
              isStrokeColor:(BOOL)isStrokeColor
{
    if (runStrokeItems.count > 0) {
        for (CJGlyphRunStrokeItem *item in runStrokeItems) {
//            if (CGRectEqualToRect(_currentClickRunStrokeItem.runBounds,item.runBounds)) {
//               [self drawBackgroundColor:c runStrokeItem:_currentClickRunStrokeItem isStrokeColor:isStrokeColor active:YES];
//            }
            if (_currentClickRunStrokeItem && NSEqualRanges(_currentClickRunStrokeItem.range,item.range) ) {
                [self drawBackgroundColor:c runStrokeItem:item isStrokeColor:isStrokeColor active:YES];
            }
            else{
                [self drawBackgroundColor:c runStrokeItem:item isStrokeColor:isStrokeColor active:NO];
            }
        }
    }
    
    
}

- (void)drawBackgroundColor:(CGContextRef)c
              runStrokeItem:(CJGlyphRunStrokeItem *)runStrokeItem
              isStrokeColor:(BOOL)isStrokeColor
                     active:(BOOL)active
{
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGFloat x = runStrokeItem.runBounds.origin.x-self.textInsets.left;
    CGFloat y = runStrokeItem.runBounds.origin.y;
    
    CGRect roundedRect = CGRectMake(x,y,runStrokeItem.runBounds.size.width,runStrokeItem.runBounds.size.height);
    CGPathRef glyphRunpath = [[UIBezierPath bezierPathWithRoundedRect:roundedRect cornerRadius:runStrokeItem.cornerRadius] CGPath];
    CGContextAddPath(c, glyphRunpath);
    
    if (isStrokeColor) {
        CGContextSetStrokeColorWithColor(c, CGColorRefFromColor((active?runStrokeItem.activeStrokeColor:runStrokeItem.strokeColor)));
        CGContextSetLineWidth(c, runStrokeItem.lineWidth);
        CGContextStrokePath(c);
    }
    else {
        CGContextSetFillColorWithColor(c, CGColorRefFromColor((active?runStrokeItem.activeFillColor:runStrokeItem.fillColor)));
        CGContextFillPath(c);
    }
}

// 插入图片
- (void)drawImageLine:(CTLineRef)line
              context:(CGContextRef)c
          lineOrigins:(CGPoint[])lineOrigins
            lineIndex:(CFIndex)lineIndex
{
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (int j = 0; j < CFArrayGetCount(runs); j++) {
        CGFloat runAscent;
        CGFloat runDescent;
        CGPoint lineOrigin = lineOrigins[lineIndex];
        //获取每个CTRun
        CTRunRef run = CFArrayGetValueAtIndex(runs, j);
        NSDictionary* attributes = (NSDictionary*)CTRunGetAttributes(run);
        CGRect runRect;
        //调整CTRun的rect
        runRect.size.width = CTRunGetTypographicBounds(run, CFRangeMake(0,0), &runAscent, &runDescent, NULL);
        
        runRect = CGRectMake(lineOrigin.x + CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, NULL), lineOrigin.y - runDescent, runRect.size.width, runAscent + runDescent);
        
        NSDictionary *imgInfoDic = attributes[kCJImageAttributeName];
        if (imgInfoDic[@"imageName"]) {
            UIImage *image = [UIImage imageNamed:imgInfoDic[@"imageName"]];
            if (image) {
                CGRect imageDrawRect;
                CGFloat imageSizeWidth = ceil(runRect.size.width);
                CGFloat imageSizeHeight = ceil(runRect.size.height);
                imageDrawRect.size = CGSizeMake(imageSizeWidth, imageSizeHeight);
                imageDrawRect.origin.x = runRect.origin.x + lineOrigin.x;
                imageDrawRect.origin.y = lineOrigin.y;
                CGContextDrawImage(c, imageDrawRect, image.CGImage);
            }
            
        }
    }
}

// 计算可点击链点，以及需要填充背景或边框线的run数组
- (NSArray <CJGlyphRunStrokeItem *>*)calculateRunStrokeItemsFrame:(CTFrameRef)frame inRect:(CGRect)rect {
 
    NSArray *lines = (__bridge NSArray *)CTFrameGetLines(frame);
    CGPoint origins[[lines count]];
    CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), origins);
    
    NSMutableArray *allStrokePathItems = [NSMutableArray arrayWithCapacity:3];
    
    CFIndex lineIndex = 0;
    // 遍历所有行
//    for (id line in lines) {
    for (int i = 0; i < (self.numberOfLines != 0?self.numberOfLines:lines.count); i ++ ) {
        id line = lines[i];
        _lastGlyphRunStrokeItem = nil;
        
        CGFloat ascent = 0.0f, descent = 0.0f, leading = 0.0f;
        CGFloat width = (CGFloat)CTLineGetTypographicBounds((__bridge CTLineRef)line, &ascent, &descent, &leading);
        CGFloat ascentAndDescent = ascent + descent;
        
        // 先获取每一行所有的runStrokeItems数组
        NSMutableArray *strokePathItems = [NSMutableArray arrayWithCapacity:3];
        
        //遍历每一行的所有glyphRun
        for (id glyphRun in (__bridge NSArray *)CTLineGetGlyphRuns((__bridge CTLineRef)line)) {
            
            NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes((__bridge CTRunRef) glyphRun);
            
            UIColor *strokeColor = colorWithAttributeName(attributes, kCJBackgroundStrokeColorAttributeName);
            if (!CJLabelIsNull(attributes[kCJLinkAttributesName]) && !isNotClearColor(strokeColor)) {
                strokeColor = colorWithAttributeName(attributes[kCJLinkAttributesName], kCJBackgroundStrokeColorAttributeName);
            }
            UIColor *fillColor = colorWithAttributeName(attributes, kCJBackgroundFillColorAttributeName);
            if (!CJLabelIsNull(attributes[kCJLinkAttributesName]) && !isNotClearColor(fillColor)) {
                fillColor = colorWithAttributeName(attributes[kCJLinkAttributesName], kCJBackgroundFillColorAttributeName);
            }
            
            UIColor *activeStrokeColor = colorWithAttributeName(attributes, kCJActiveBackgroundStrokeColorAttributeName);
            if (!CJLabelIsNull(attributes[kCJActiveLinkAttributesName]) && !isNotClearColor(activeStrokeColor)) {
                activeStrokeColor = colorWithAttributeName(attributes[kCJActiveLinkAttributesName], kCJActiveBackgroundStrokeColorAttributeName);
            }
            if (!isNotClearColor(activeStrokeColor)) {
                activeStrokeColor = strokeColor;
            }
            
            UIColor *activeFillColor = colorWithAttributeName(attributes, kCJActiveBackgroundFillColorAttributeName);
            if (!CJLabelIsNull(attributes[kCJActiveLinkAttributesName]) && !isNotClearColor(activeFillColor)) {
                activeFillColor = colorWithAttributeName(attributes[kCJActiveLinkAttributesName], kCJActiveBackgroundFillColorAttributeName);
            }
            if (!isNotClearColor(activeFillColor)) {
                activeFillColor = fillColor;
            }
            
            CGFloat lineWidth = [[attributes objectForKey:kCJBackgroundLineWidthAttributeName] floatValue];
            if (!CJLabelIsNull(attributes[kCJActiveLinkAttributesName]) && lineWidth == 0) {
                lineWidth = [[attributes[kCJActiveLinkAttributesName] objectForKey:kCJBackgroundLineCornerRadiusAttributeName] floatValue];
            }
            CGFloat cornerRadius = [[attributes objectForKey:kCJBackgroundLineCornerRadiusAttributeName] floatValue];
            if (!CJLabelIsNull(attributes[kCJActiveLinkAttributesName]) && cornerRadius == 0) {
                cornerRadius = [[attributes[kCJActiveLinkAttributesName] objectForKey:kCJBackgroundLineCornerRadiusAttributeName] floatValue];
            }
            lineWidth = lineWidth == 0?1:lineWidth;
            cornerRadius = cornerRadius == 0?5:cornerRadius;
            
            BOOL isLink = [attributes[kCJIsLinkAttributesName] boolValue];
            
            //点击链点的range（当isLink == YES才存在）
            NSString *linkRangeStr = [attributes objectForKey:kCJLinkRangeAttributesName];
            //点击链点是否需要重绘
            BOOL needRedrawn = [attributes[kCJLinkNeedRedrawnAttributesName] boolValue];
            
            // 当前glyphRun是一个可点击链点
            if (isLink) {
                CJGlyphRunStrokeItem *runStrokeItem = [self runStrokeItemFromGlyphRun:glyphRun line:line origins:origins lineIndex:lineIndex inRect:rect width:width];
                
                runStrokeItem.strokeColor = strokeColor;
                runStrokeItem.fillColor = fillColor;
                runStrokeItem.lineWidth = lineWidth;
                runStrokeItem.cornerRadius = cornerRadius;
                runStrokeItem.activeStrokeColor = activeStrokeColor;
                runStrokeItem.activeFillColor = activeFillColor;
                runStrokeItem.range = NSRangeFromString(linkRangeStr);
                runStrokeItem.isLink = YES;
                runStrokeItem.needRedrawn = needRedrawn;
                
                NSDictionary *imgInfoDic = attributes[kCJImageAttributeName];
                if (imgInfoDic[@"imageName"]) {
                    UIImage *image = [UIImage imageNamed:imgInfoDic[@"imageName"]];
                    runStrokeItem.image = image;
                }
                if (!CJLabelIsNull(attributes[kCJClickLinkBlockAttributesName])) {
                    runStrokeItem.linkBlock = attributes[kCJClickLinkBlockAttributesName];
                }
                if (!CJLabelIsNull(attributes[kCJLongPressBlockAttributesName])) {
                    runStrokeItem.longPressBlock = attributes[kCJLongPressBlockAttributesName];
                }
                
                [strokePathItems addObject:runStrokeItem];
            }else{
                //不是可点击链点。但存在自定义边框线或背景色
                if (isNotClearColor(strokeColor) || isNotClearColor(fillColor) || isNotClearColor(activeStrokeColor) || isNotClearColor(activeFillColor)) {
                    CJGlyphRunStrokeItem *runStrokeItem = [self runStrokeItemFromGlyphRun:glyphRun line:line origins:origins lineIndex:lineIndex inRect:rect width:width];
                    
                    runStrokeItem.strokeColor = strokeColor;
                    runStrokeItem.fillColor = fillColor;
                    runStrokeItem.lineWidth = lineWidth;
                    runStrokeItem.cornerRadius = cornerRadius;
                    runStrokeItem.activeStrokeColor = activeStrokeColor;
                    runStrokeItem.activeFillColor = activeFillColor;
                    runStrokeItem.isLink = NO;
                    
                    [strokePathItems addObject:runStrokeItem];
                }
            }
            
        }
        
        // 再判断是否有需要合并的runStrokeItems
        [allStrokePathItems addObjectsFromArray:[self mergeLineSameStrokePathItems:strokePathItems ascentAndDescent:ascentAndDescent]];
        lineIndex ++;
    }
    
    return allStrokePathItems;
}

- (CJGlyphRunStrokeItem *)runStrokeItemFromGlyphRun:(id)glyphRun
                                               line:(id)line
                                            origins:(CGPoint[])origins
                                          lineIndex:(CFIndex)lineIndex
                                             inRect:(CGRect)rect
                                              width:(CGFloat)width
{
    CGRect runBounds = CGRectZero;
    CGFloat runAscent = 0.0f;
    CGFloat runDescent = 0.0f;
    
    runBounds.size.width = (CGFloat)CTRunGetTypographicBounds((__bridge CTRunRef)glyphRun, CFRangeMake(0, 0), &runAscent, &runDescent, NULL);
    runBounds.size.height = runAscent + runDescent;
    
    CGFloat xOffset = 0.0f;
    CFRange glyphRange = CTRunGetStringRange((__bridge CTRunRef)glyphRun);
    switch (CTRunGetStatus((__bridge CTRunRef)glyphRun)) {
        case kCTRunStatusRightToLeft:
            xOffset = CTLineGetOffsetForStringIndex((__bridge CTLineRef)line, glyphRange.location + glyphRange.length, NULL);
            break;
        default:
            xOffset = CTLineGetOffsetForStringIndex((__bridge CTLineRef)line, glyphRange.location, NULL);
            break;
    }
    
    runBounds.origin.x = origins[lineIndex].x + rect.origin.x + xOffset;
    runBounds.origin.y = origins[lineIndex].y - runDescent;
    
    if (CGRectGetWidth(runBounds) > width) {
        runBounds.size.width = width;
    }

    //转换为UIKit坐标系统
    CGRect locBounds = [self convertRectFromLoc:runBounds];
    CJGlyphRunStrokeItem *runStrokeItem = [[CJGlyphRunStrokeItem alloc]init];
    runStrokeItem.runBounds = runBounds;
    runStrokeItem.locBounds = locBounds;
    
    return runStrokeItem;
}
//判断是否有需要合并的runStrokeItems
- (NSMutableArray <CJGlyphRunStrokeItem *>*)mergeLineSameStrokePathItems:(NSArray <CJGlyphRunStrokeItem *>*)lineStrokePathItems
                                             ascentAndDescent:(CGFloat)ascentAndDescent
{
    NSMutableArray *mergeLineStrokePathItems = [[NSMutableArray alloc] initWithCapacity:3];
    
    if (lineStrokePathItems.count > 1) {
        
        NSMutableArray *strokePathTempItems = [NSMutableArray arrayWithCapacity:3];
        for (NSInteger i = 0; i < lineStrokePathItems.count; i ++) {
            CJGlyphRunStrokeItem *item = lineStrokePathItems[i];
            
            //第一个item无需判断
            if (i == 0) {
                _lastGlyphRunStrokeItem = item;
            }else{
                
                CGRect runBounds = item.runBounds;
                UIColor *strokeColor = item.strokeColor;
                UIColor *fillColor = item.fillColor;
                UIColor *activeStrokeColor = item.activeStrokeColor;
                UIColor *activeFillColor = item.activeFillColor;
                CGFloat lineWidth = item.lineWidth;
                CGFloat cornerRadius = item.cornerRadius;
                
                CGRect lastRunBounds = _lastGlyphRunStrokeItem.runBounds;
                UIColor *lastStrokeColor = _lastGlyphRunStrokeItem.strokeColor;
                UIColor *lastFillColor = _lastGlyphRunStrokeItem.fillColor;
                UIColor *lastActiveStrokeColor = _lastGlyphRunStrokeItem.activeStrokeColor;
                UIColor *lastActiveFillColor = _lastGlyphRunStrokeItem.activeFillColor;
                CGFloat lastLineWidth = _lastGlyphRunStrokeItem.lineWidth;
                CGFloat lastCornerRadius = _lastGlyphRunStrokeItem.cornerRadius;
                
                BOOL sameColor = ({
                    BOOL same = NO;
                    if (isSameColor(strokeColor,lastStrokeColor) &&
                        isSameColor(fillColor,lastFillColor) &&
                        isSameColor(activeStrokeColor,lastActiveStrokeColor) &&
                        isSameColor(activeFillColor,lastActiveFillColor))
                    {
                        same = YES;
                    }
                    same;
                });
                
                BOOL needMerge = NO;
                //可点击链点
                if (item.isLink && _lastGlyphRunStrokeItem.isLink) {
                    NSRange range = item.range;
                    NSRange lastRange = _lastGlyphRunStrokeItem.range;
                    //需要合并的点击链点
                    if (NSEqualRanges(range,lastRange)) {
                        needMerge = YES;
                        lastRunBounds = CGRectMake(compareMaxNum(lastRunBounds.origin.x,runBounds.origin.x,NO),
                                                   compareMaxNum(lastRunBounds.origin.y,runBounds.origin.y,NO),
                                                   lastRunBounds.size.width + runBounds.size.width,
                                                   compareMaxNum(lastRunBounds.size.height,runBounds.size.height,YES));
                        _lastGlyphRunStrokeItem.runBounds = lastRunBounds;
                        _lastGlyphRunStrokeItem.locBounds = [self convertRectFromLoc:lastRunBounds];
                    }
                }else if (!item.isLink && !_lastGlyphRunStrokeItem.isLink){
                    //非点击链点，但是是需要合并的连续run
                    if (sameColor && lineWidth == lastLineWidth && cornerRadius == lastCornerRadius &&
                        lastRunBounds.origin.x + lastRunBounds.size.width == runBounds.origin.x) {
                        
                        needMerge = YES;
                        lastRunBounds = CGRectMake(compareMaxNum(lastRunBounds.origin.x,runBounds.origin.x,NO),
                                                   compareMaxNum(lastRunBounds.origin.y,runBounds.origin.y,NO),
                                                   lastRunBounds.size.width + runBounds.size.width,
                                                   compareMaxNum(lastRunBounds.size.height,runBounds.size.height,YES));
                        _lastGlyphRunStrokeItem.runBounds = lastRunBounds;
                        _lastGlyphRunStrokeItem.locBounds = [self convertRectFromLoc:lastRunBounds];
                    }
                }
                
                //没有发生合并
                if (!needMerge) {
                    
                    _lastGlyphRunStrokeItem = [self adjustItemHeight:_lastGlyphRunStrokeItem height:ascentAndDescent];
                    [strokePathTempItems addObject:[_lastGlyphRunStrokeItem copy]];
                    
                    _lastGlyphRunStrokeItem = item;
                    
                    //已经是最后一个run
                    if (i == lineStrokePathItems.count - 1) {
                        _lastGlyphRunStrokeItem = [self adjustItemHeight:_lastGlyphRunStrokeItem height:ascentAndDescent];
                        [strokePathTempItems addObject:[_lastGlyphRunStrokeItem copy]];
                    }
                }
                //有合并
                else{
                    //已经是最后一个run
                    if (i == lineStrokePathItems.count - 1) {
                        _lastGlyphRunStrokeItem = [self adjustItemHeight:_lastGlyphRunStrokeItem height:ascentAndDescent];
                        [strokePathTempItems addObject:[_lastGlyphRunStrokeItem copy]];
                    }
                }
            }
        }
        [mergeLineStrokePathItems addObjectsFromArray:strokePathTempItems];
    }
    else{
        if (lineStrokePathItems.count == 1) {
            CJGlyphRunStrokeItem *item = lineStrokePathItems[0];
            item = [self adjustItemHeight:item height:ascentAndDescent];
            [mergeLineStrokePathItems addObject:item];
        }
        
    }
    return mergeLineStrokePathItems;
}

- (CJGlyphRunStrokeItem *)adjustItemHeight:(CJGlyphRunStrokeItem *)item height:(CGFloat)ascentAndDescent {
    // runBounds小于 ascent + Descent 时，rect扩大 1
    if (item.runBounds.size.height < ascentAndDescent) {
        item.runBounds = CGRectInset(item.runBounds,-1,-1);
        item.locBounds = [self convertRectFromLoc:item.runBounds];;
    }
    return item;
}

- (NSArray <CJGlyphRunStrokeItem *>*)getLinkStrokeItems:(NSArray *)strokeItems {
    NSMutableArray *linkArray = [NSMutableArray arrayWithCapacity:4];
    for (CJGlyphRunStrokeItem *item in strokeItems) {
        if (item.isLink) {
            [linkArray addObject:item];
        }
    }
    return linkArray;
}

/**
 将系统坐标转换为屏幕坐标

 @param rect 坐标原点在左下角的 rect
 @return 坐标原点在左上角的 rect
 */
- (CGRect)convertRectFromLoc:(CGRect)rect {
    return CGRectMake(rect.origin.x ,
                      self.bounds.size.height - rect.origin.y - rect.size.height ,
                      rect.size.width,
                      rect.size.height);
}

#pragma mark - UIView

- (CGSize)sizeThatFits:(CGSize)size {
    if (!self.attributedText) {
        return [super sizeThatFits:size];
    } else {
        NSAttributedString *string = [self renderedAttributedText];
        
        CGSize labelSize = CTFramesetterSuggestFrameSizeForAttributedStringWithConstraints([self framesetter], string, size, (NSUInteger)self.numberOfLines);
        labelSize.width += self.textInsets.left + self.textInsets.right;
        labelSize.height += self.textInsets.top + self.textInsets.bottom;
        
        return labelSize;
    }
}

- (CGSize)intrinsicContentSize {
    return [self sizeThatFits:[super intrinsicContentSize]];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self linkAtPoint:point] || !self.userInteractionEnabled || self.hidden || self.alpha < 0.01) {
        return [super hitTest:point withEvent:event];
    }
    
    return self;
}

#pragma mark - UIResponder

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)canPerformAction:(SEL)action
              withSender:(__unused id)sender
{
#if !TARGET_OS_TV
    return (action == @selector(copy:));
#else
    return NO;
#endif
}

- (BOOL)containslinkAtPoint:(CGPoint)point {
    return [self linkAtPoint:point] != nil;
}

- (CJGlyphRunStrokeItem *)linkAtPoint:(CGPoint)point {
    
    if (!CGRectContainsPoint(CGRectInset(self.bounds, -15.f, -15.f), point) || _linkStrokeItemArray.count == 0) {
        return nil;
    }
    
    CJGlyphRunStrokeItem *resultItem = [self clickLinkItemAtRadius:0 aroundPoint:point];
    
    if (!resultItem && self.extendsLinkTouchArea) {
        resultItem = [self clickLinkItemAtRadius:0 aroundPoint:point]
        ?: [self clickLinkItemAtRadius:2.5 aroundPoint:point]
        ?: [self clickLinkItemAtRadius:5 aroundPoint:point]
        ?: [self clickLinkItemAtRadius:7.5 aroundPoint:point];
    }
    return resultItem;
}

- (CJGlyphRunStrokeItem *)clickLinkItemAtRadius:(CGFloat)radius aroundPoint:(CGPoint)point {
    CJGlyphRunStrokeItem *resultItem = nil;
    for (CJGlyphRunStrokeItem *item in _linkStrokeItemArray) {
        CGRect bounds = item.locBounds;
        
        CGFloat top = self.textInsets.top;
        CGFloat bottom = self.textInsets.bottom;
        bounds.origin.y = bounds.origin.y + top - bottom + _yOffset;
        if (radius > 0) {
            bounds = CGRectInset(bounds,-radius,-radius);
        }
        if (CGRectContainsPoint(bounds, point)) {
            resultItem = item;
        }
    }
    return resultItem;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    _currentClickRunStrokeItem = nil;
    CJGlyphRunStrokeItem *item = [self linkAtPoint:[touch locationInView:self]];
    if (item) {
        _currentClickRunStrokeItem = item;
        _needRedrawn = _currentClickRunStrokeItem.needRedrawn;
        [self setNeedsFramesetter];
        [self setNeedsDisplay];
        //立即刷新界面
        [CATransaction flush];
    }
    
    if (!item) {
        [super touchesBegan:touches withEvent:event];
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_longPress) {
        [super touchesEnded:touches withEvent:event];
    }else{
        if (_currentClickRunStrokeItem) {
            if (_currentClickRunStrokeItem.linkBlock) {
                NSAttributedString *attributedString = [self.attributedText attributedSubstringFromRange:_currentClickRunStrokeItem.range];
                _currentClickRunStrokeItem.linkBlock(attributedString, _currentClickRunStrokeItem.image, _currentClickRunStrokeItem.parameter, _currentClickRunStrokeItem.range);
            }
            _needRedrawn = _currentClickRunStrokeItem.needRedrawn;
            _currentClickRunStrokeItem = nil;
            [self setNeedsFramesetter];
            [self setNeedsDisplay];
        } else {
            [super touchesEnded:touches withEvent:event];
        }
    }

}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    if (_longPress) {
        [super touchesCancelled:touches withEvent:event];
    }else{
        if (_currentClickRunStrokeItem) {
            _needRedrawn = NO;
            _currentClickRunStrokeItem = nil;
        } else {
            [super touchesCancelled:touches withEvent:event];
        }
    }
    
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    return [self containslinkAtPoint:[touch locationInView:self]];
}

#pragma mark - UILongPressGestureRecognizer

- (void)longPressGestureDidFire:(UILongPressGestureRecognizer *)sender {
    switch (sender.state) {
        case UIGestureRecognizerStateBegan: {
            _longPress = YES;
            break;
        }
        case UIGestureRecognizerStateEnded:{
            _longPress = NO;
            if (_currentClickRunStrokeItem) {
                if (_currentClickRunStrokeItem.longPressBlock) {
                    NSAttributedString *attributedString = [self.attributedText attributedSubstringFromRange:_currentClickRunStrokeItem.range];
                    _currentClickRunStrokeItem.longPressBlock(attributedString, _currentClickRunStrokeItem.image, _currentClickRunStrokeItem.parameter, _currentClickRunStrokeItem.range);
                }
                _needRedrawn = _currentClickRunStrokeItem.needRedrawn;
                _currentClickRunStrokeItem = nil;
                [self setNeedsFramesetter];
                [self setNeedsDisplay];
                [CATransaction flush];
            }
            break;
        }
        default:
            break;
    }
}

@end


@implementation CJGlyphRunStrokeItem

- (id)copyWithZone:(NSZone *)zone {
    CJGlyphRunStrokeItem *item = [[[self class] allocWithZone:zone] init];
    item.strokeColor = [self.strokeColor copyWithZone:zone];
    item.fillColor = self.fillColor;
    item.lineWidth = self.lineWidth;
    item.runBounds = self.runBounds;
    item.locBounds = self.locBounds;
    item.cornerRadius = self.cornerRadius;
    item.activeFillColor = self.activeFillColor;
    item.activeStrokeColor = self.activeStrokeColor;
    item.image = self.image;
    item.range = self.range;
    item.parameter = self.parameter;
    item.linkBlock = self.linkBlock;
    item.longPressBlock = self.longPressBlock;
    item.isLink = self.isLink;
    item.needRedrawn = self.needRedrawn;
    return item;
}

@end
