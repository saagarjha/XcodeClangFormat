//
//  XCSourceTextRange+ClangFormat.m
//  clang-format
//
//  Created by Saagar Jha on 9/23/18.
//  Copyright © 2018 Mapbox. All rights reserved.
//

#import "XCSourceTextRange+ClangFormat.h"

@implementation XCSourceTextRange (ClangFormat)
- (BOOL)isEmpty {
    return self.start.line == self.end.line && self.start.column == self.end.column;
}
@end
