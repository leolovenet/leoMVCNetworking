#import "GalleryParserOperation.h"
#import "Logging.h"
#include <xlocale.h>                                    // for strptime_l

NSString * kGalleryParserResultPhotoID       = @"photoID";
NSString * kGalleryParserResultName          = @"name";
NSString * kGalleryParserResultDate          = @"date";
NSString * kGalleryParserResultPhotoPath     = @"photoPath";
NSString * kGalleryParserResultThumbnailPath = @"thumbnailPath";

/*
    o 本类继承自 NSOperation,  通过重写 main 方法 来定义自己的 NSOperation.
        这种方法非常简单，开发者不需要管理一些状态属性(例如isExecuting 和 isFinished )，当 main 方法返回的时候，这个NSOperation就结束了
*/

@interface GalleryParserOperation () <NSXMLParserDelegate>

// read/write variants of public properties

@property (copy,   readwrite) NSError *                 error;

// private properties
#if ! defined(NDEBUG)
@property (assign, readwrite) NSTimeInterval            debugDelaySoFar;
#endif

@property (retain, readonly ) NSMutableArray *          mutableResults;
@property (retain, readwrite) NSXMLParser *             parser;
@property (retain, readonly ) NSMutableDictionary *     itemProperties;

@end

@implementation GalleryParserOperation


- (id)initWithData:(NSData *)data
{
    assert(data != nil);
    self = [super init];
    if (self != nil) {
        self->_data = [data copy];  //copy 一份数据
        
        self->_mutableResults  = [[NSMutableArray alloc] init];
        assert(self->_mutableResults != nil);
        
        self->_itemProperties = [[NSMutableDictionary alloc] init];
        assert(self->_itemProperties != nil);
    }
    return self;
}

- (void)dealloc
{
    [self->_data release];
    [self->_error release];
    [self->_parser release];
    [self->_mutableResults release];
    [self->_itemProperties release];
    [super dealloc];
}

#if ! defined(NDEBUG)
@synthesize debugDelay      = _debugDelay;
@synthesize debugDelaySoFar = _debugDelaySoFar;
#endif

@synthesize data            = _data; //初始化对象是,传入的 data 参数的一份 copy
@synthesize error           = _error;

@synthesize mutableResults  = _mutableResults;  //NSMutableArray, 用来保存最后的结果集合
@synthesize parser          = _parser;          //NSXMLParser 对象,用来执行 parse 动作
@synthesize itemProperties  = _itemProperties;  //NSMutableDictionary 对象,一个临时存储变量,用来存储 xml 里的一个 photo element 的属性


// Parses the supplied XML date string and returns an NSDate object.
// We avoid NSDateFormatter here and do the work using the much lighter weight strptime_l.
// Dates are of the form "2006-07-30T07:47:17Z".
// 由photo元素的date属性得到的NSDate对象
+ (NSDate *)dateFromDateString:(NSString *)string
{
    struct tm   now;
    NSDate *    result;
    BOOL        success;
    
    result = nil;
    success = strptime_l([string UTF8String], "%Y-%m-%dT%H:%M:%SZ", &now, NULL) != NULL;
    if (success) {
        result = [NSDate dateWithTimeIntervalSince1970:timelocal(&now)];
    }
    
    return result;
}


 // Returns a copy of the current results.
- (NSArray *)results
{
    return [[self->_mutableResults copy] autorelease];
}

#pragma mark - 入列后开始执行的函数
- (void)main
{
    BOOL        success;
    
    // Set up the parser.
    // We keep this in a property so that our delegate callbacks have access to it.
    
    assert(self.data != nil);
    self.parser = [[[NSXMLParser alloc] initWithData:self.data] autorelease];
    assert(self.parser != nil);
    
    self.parser.delegate = self;
    
    // Do the parse.
    
    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse start"];
    
    success = [self.parser parse];
    if ( ! success ) { //如果分析 xml 动作没有成功执行
        
        // If our parser delegate callbacks already set an error, we ignore the error coming back from NSXMLParser.
        // Our delegate callbacks have the most accurate error info.
        
        if (self.error == nil) {
            self.error = [self.parser parserError];
            assert(self.error != nil);
        }
    }
    
    
    
    // In the debug version, if we've been told to delay, do so.  This gives
    // us time to test the cancellation path.
#if ! defined(NDEBUG)
  {
    while (self.debugDelaySoFar < self.debugDelay) {
        // We always sleep in one second intervals.  I could do the maths to
        // sleep for the remaining amount of time or one second, whichever
        // is the least, but hey, this is debugging code.
        
        [NSThread sleepForTimeInterval:1.0];
        self.debugDelaySoFar += 1.0;
        
        if ( [self isCancelled] ) {
            // If we notice the cancel, we override any error we got from the XML.
            self.error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
            break;
        }
    }
  }
#endif
    
    if (self.error == nil) {
        [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse success"];
    } else {
        [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse failed %@", self.error];
    }
    
    self.parser = nil;  //parser动作已经完成了,(可能失败),删除它.
}

/*
    Here's an example of a "photo" element in our XML:
    
   <photo name="Kids In A Box" date="2006-07-30T07:47:17Z" id="12345">
        <image kind="original" src="originals/IMG_1282.JPG" srcURL="originals/IMG_1282.JPG" srcname="IMG_1282.JPG" size="1241626" sizeText="1.2 MB" type="image">
        </image>
        <image kind="image" src="images/IMG_1282.JPG" srcURL="images/IMG_1282.JPG" srcname="IMG_1282.JPG" size="1129805" sizeText="1 MB" type="image" width="2048" height="1536"></image>
        <image kind="thumbnail" src="thumbnails/IMG_1282.jpg" srcURL="thumbnails/IMG_1282.jpg" srcname="IMG_1282.jpg" size="29295" sizeText="28.6 KB" type="image" width="300" height="225"></image>
    </photo>
*/



#pragma mark - NSXMLParserDelegate Protocal Callback
/*!
 *  Sent by a parser object to its delegate when it encounters a start tag for a given element.

 *  @param parser           A parser object.
 *  @param elementName      A string that is the name of an element (in its start tag).
 *  @param namespaceURI     If namespace processing is turned on, contains the URI for the current namespace as a string object.
 *  @param qName            If namespace processing is turned on, contains the qualified name for the current namespace as a string object.
 *  @param attributeDict    A dictionary that contains any attributes associated with the element. Keys are the names of attributes, and values are attribute values.
 */
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict
{
    assert(parser == self.parser);
    #pragma unused(parser)
    #pragma unused(namespaceURI)
    #pragma unused(qName)
    #pragma unused(attributeDict)
    
    // In the debug build, if we've been told to delay, and we haven't already delayed 
    // enough, just sleep for 0.1 seconds.
    #if ! defined(NDEBUG)
        if (self.debugDelaySoFar < self.debugDelay) {
            [NSThread sleepForTimeInterval:0.1];
            self.debugDelaySoFar += 0.1;
        }
    #endif
    
    // Check for cancellation at the start of each element.
    // 检查 parse 动作是不是被取消了
    if ( [self isCancelled] ) {
        self.error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        [self.parser abortParsing];
        
    } else if ( [elementName isEqual:@"photo"] ) {  //遇到的 element 是一个 photo 元素
        NSString *  tmpStr;
        NSString *  photoID;
        NSString *  name;
        NSDate *    date;
        
        // We're at the start of a "photo" element.  Set up the itemProperties dictionary.

        [self.itemProperties removeAllObjects]; //删除上个 Photo 元素里的 item 数据
        
        photoID = nil;
        name = nil;
        date = nil;
        
        photoID = [attributeDict objectForKey:@"id"];
        name    = [attributeDict objectForKey:@"name"];
        tmpStr  = [attributeDict objectForKey:@"date"];

        if (tmpStr != nil) {
            date = [[self class] dateFromDateString:tmpStr];
            if (date == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo date error '%@'", tmpStr];
            }
        }

        if ( (photoID == nil) || ([photoID length] == 0) ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'id'"];
        } else if ( (name == nil) || ([name length] == 0) ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'name'"];
        } else if (date == nil) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing 'date'"];
        } else {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo start %@", photoID];
            [self.itemProperties setObject:photoID forKey:kGalleryParserResultPhotoID];
            [self.itemProperties setObject:name    forKey:kGalleryParserResultName];
            [self.itemProperties setObject:date    forKey:kGalleryParserResultDate];
        }
    
    } else if ( [elementName isEqual:@"image"] ) {  //遇到的 element 是一个 photo 元素里的image元素
        
        if ( [self.itemProperties count] == 0 ) {
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo image skipped, out of context"];
        } else {
            NSString *  kindStr;
            NSString *  srcURLStr;
            
            // We're at the start of an "image" element.
            // Check to see whether it's an image we care about.
            // If so, add the "srcURL" attribute to our itemProperties dictionary.
            
            kindStr   = [attributeDict objectForKey:@"kind"];    // original,image,thumbnail
            srcURLStr = [attributeDict objectForKey:@"srcURL"];
            
            if ( (srcURLStr != nil) && ([srcURLStr length] != 0) ) {
                if ( [kindStr isEqual:@"image"] ) {
                    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo image '%@'", srcURLStr];
                    [self.itemProperties setObject:srcURLStr forKey:kGalleryParserResultPhotoPath];
                } else if ( [kindStr isEqual:@"thumbnail"] ) {
                    [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo thumbnail '%@'", srcURLStr];
                    [self.itemProperties setObject:srcURLStr forKey:kGalleryParserResultThumbnailPath];
                }
            }
            
        }
    }
}


/*!
 *  Sent by a parser object to its delegate when it encounters an end tag for a specific element.
 *
 *  @param parser           A parser object.
 *  @param elementName      A string that is the name of an element (in its end tag).
 *  @param namespaceURI     If namespace processing is turned on, contains the URI for the current namespace as a string object.
 *  @param qName            If namespace processing is turned on, contains the qualified name for the current namespace as a string object.
 */
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    assert(parser == self.parser);
    #pragma unused(parser)
    #pragma unused(namespaceURI)
    #pragma unused(qName)
    
    // At the end of the "photo" element, check to see we got all of the required 
    // properties and, if so, add an item to the result.
    
    if ( [elementName isEqual:@"photo"] ) {  // 一个 photo 元素已经分析完了.
        if ([self.itemProperties count] == 0) { //一个有用的属性都没有?那就是遇到错误了
            [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, out of context"];
        } else {
            if ([self.itemProperties objectForKey:kGalleryParserResultPhotoPath] == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing image"];
            } else if ([self.itemProperties objectForKey:kGalleryParserResultThumbnailPath] == nil) {
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo skipped, missing thumbnail"];
            } else {
                assert([[self.itemProperties objectForKey:kGalleryParserResultPhotoID      ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultName         ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultDate         ] isKindOfClass:[NSDate   class]]);//由photo元素的date属性得到的NSDate对象
                assert([[self.itemProperties objectForKey:kGalleryParserResultPhotoPath    ] isKindOfClass:[NSString class]]);
                assert([[self.itemProperties objectForKey:kGalleryParserResultThumbnailPath] isKindOfClass:[NSString class]]);
                [[QLog log] logOption:kLogOptionXMLParseDetails withFormat:@"xml parse photo success %@", [self.itemProperties objectForKey:kGalleryParserResultPhotoID]];
                [self.mutableResults addObject:[[self.itemProperties copy] autorelease]]; // 添加到结果集合
                [self.itemProperties removeAllObjects]; //清空这个 photo 元素的所有属性
            }
        }
    }
    
}

@end


