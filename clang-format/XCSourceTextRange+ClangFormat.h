//
//  XCSourceTextRange+ClangFormat.h
//  clang-format
//
//  Created by Saagar Jha on 9/23/18.
//  Copyright © 2018 Mapbox. All rights reserved.
//

#import <XcodeKit/XcodeKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCSourceTextRange (ClangFormat)
- (BOOL)isEmpty;
@end

NS_ASSUME_NONNULL_END
