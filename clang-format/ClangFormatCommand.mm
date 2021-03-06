#import "ClangFormatCommand.h"

#import "XCSourceTextRange+ClangFormat.h"

#import <AppKit/AppKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wconversion"
#include <clang/Format/Format.h>
#pragma clang diagnostic pop

// Generates a list of offsets for ever line in the array.
void updateOffsets(std::vector<size_t>& offsets, NSMutableArray<NSString*>* lines) {
    offsets.clear();
    offsets.reserve(lines.count + 1);
    offsets.push_back(0);
    size_t offset = 0;
    for (NSString* line in lines) {
        offsets.push_back(offset += line.length);
    }
}

NSErrorDomain errorDomain = @"ClangFormatError";

@implementation ClangFormatCommand

NSUserDefaults* defaults = nil;

- (NSData*)getCustomStyle {
    // First, read the regular bookmark because it could've been changed by the wrapper app.
    NSData* regularBookmark = [defaults dataForKey:@"regularBookmark"];
    NSURL* regularURL = nil;
    BOOL regularStale = NO;
    if (regularBookmark) {
        regularURL = [NSURL URLByResolvingBookmarkData:regularBookmark
                                               options:NSURLBookmarkResolutionWithoutUI
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&regularStale
                                                 error:nil];
    }

    if (!regularURL) {
        return nil;
    }

    // Then read the security URL, which is the URL we're actually going to use to access the file.
    NSData* securityBookmark = [defaults dataForKey:@"securityBookmark"];
    NSURL* securityURL = nil;
    BOOL securityStale = NO;
    if (securityBookmark) {
        securityURL = [NSURL URLByResolvingBookmarkData:securityBookmark
                                                options:NSURLBookmarkResolutionWithSecurityScope |
                                                        NSURLBookmarkResolutionWithoutUI
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&securityStale
                                                  error:nil];
    }

    // Clear out the security URL if it's no longer matching the regular URL.
    if (securityStale == YES ||
        (securityURL && ![[securityURL path] isEqualToString:[regularURL path]])) {
        securityURL = nil;
    }

    if (!securityURL && regularStale == NO) {
        // Attempt to create new security URL from the regular URL to persist across system reboots.
        NSError* error = nil;
        securityBookmark = [regularURL
                   bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope |
                                           NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
            includingResourceValuesForKeys:nil
                             relativeToURL:nil
                                     error:&error];
        [defaults setObject:securityBookmark forKey:@"securityBookmark"];
        securityURL = regularURL;
    }

    if (securityURL) {
        // Finally, attempt to read the .clang-format file
        NSError* error = nil;
        [securityURL startAccessingSecurityScopedResource];
        NSData* data = [NSData dataWithContentsOfURL:securityURL options:0 error:&error];
        [securityURL stopAccessingSecurityScopedResource];
        if (error) {
            NSLog(@"Error loading from security bookmark: %@", error);
        } else if (data) {
            return data;
        }
    }

    return nil;
}

- (void)performCommandWithInvocation:(XCSourceEditorCommandInvocation*)invocation
                   completionHandler:(void (^)(NSError* _Nullable nilOrError))completionHandler {
    if (!defaults) {
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"XcodeClangFormat"];
    }

    NSString* style = [defaults stringForKey:@"style"];
    if (!style) {
        style = @"llvm";
    }

    clang::format::FormatStyle format = clang::format::getLLVMStyle();
    format.Language = clang::format::FormatStyle::LK_Cpp;
    clang::format::getPredefinedStyle("LLVM", format.Language, &format);
    if ([style isEqualToString:@"custom"]) {
        NSData* config = [self getCustomStyle];
        if (!config) {
            completionHandler([NSError
                errorWithDomain:errorDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"Could not load custom style. Please open XcodeClangFormat.app"
                       }]);
        } else {
            // parse style
            llvm::StringRef configString(reinterpret_cast<const char*>(config.bytes),
                                         config.length);
            auto error = clang::format::parseConfiguration(configString, &format);
            if (error) {
                completionHandler([NSError
                    errorWithDomain:errorDomain
                               code:0
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"Could not parse custom style: %s.",
                                                              error.message().c_str()]
                           }]);
                return;
            }
        }
    } else {
        auto success = clang::format::getPredefinedStyle(
            llvm::StringRef([style cStringUsingEncoding:NSUTF8StringEncoding]),
            clang::format::FormatStyle::LanguageKind::LK_Cpp, &format);
        if (!success) {
            completionHandler([NSError
                errorWithDomain:errorDomain
                           code:0
                       userInfo:@{
                           NSLocalizedDescriptionKey : [NSString
                               stringWithFormat:@"Could not parse default style %@", style]
                       }]);
            return;
        }
    }

    NSData* buffer = [invocation.buffer.completeBuffer dataUsingEncoding:NSUTF8StringEncoding];
    llvm::StringRef code(reinterpret_cast<const char*>(buffer.bytes), buffer.length);

    std::vector<size_t> offsets;
    updateOffsets(offsets, invocation.buffer.lines);

    std::vector<clang::tooling::Range> ranges;
    if (invocation.buffer.selections.count != 1 || !invocation.buffer.selections.firstObject.isEmpty) {
        for (XCSourceTextRange* range in invocation.buffer.selections) {
            const size_t start = offsets[range.start.line] + range.start.column;
            const size_t end = offsets[range.end.line] + range.end.column;
            ranges.emplace_back(start, end - start);
        }
    } else {
        ranges.emplace_back(0, invocation.buffer.completeBuffer.length);
    }

    // Calculated replacements and apply them to the input buffer.
    const llvm::StringRef filename("<stdin>");
    auto replaces = clang::format::sortIncludes(format, code, ranges, filename);
    auto result = clang::tooling::applyAllReplacements(code, replaces);
    if (!result) {
        // We could not apply the calculated replacements.
        completionHandler([NSError
                           errorWithDomain:errorDomain
                           code:0
                           userInfo:@{
                                      NSLocalizedDescriptionKey : @"Failed to apply formatting replacements."
                                      }]);
        return;
    }
    ranges = clang::tooling::calculateRangesAfterReplacements(replaces, ranges);
    replaces = clang::format::reformat(format, *result, ranges, filename);
    result = clang::tooling::applyAllReplacements(*result, replaces);

    if (!result) {
        // We could not apply the calculated replacements.
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey : @"Failed to apply formatting replacements."
                   }]);
        return;
    }

    // Remove all selections before replacing the completeBuffer, otherwise we get crashes when
    // changing the buffer contents because it tries to automatically update the selections, which
    // might be out of range now.
    [invocation.buffer.selections removeAllObjects];

    // Update the entire text with the result we got after applying the replacements.
    invocation.buffer.completeBuffer = [[NSString alloc] initWithBytes:result->data()
                                                                length:result->size()
                                                              encoding:NSUTF8StringEncoding];

    // Recalculate the line offsets.
    updateOffsets(offsets, invocation.buffer.lines);

    // Update the selections with the shifted code positions.
    for (auto& range : ranges) {
        const size_t start = replaces.getShiftedCodePosition(range.getOffset());
        const size_t end = replaces.getShiftedCodePosition(range.getOffset() + range.getLength());

        // In offsets, find the value that is smaller than start.
        auto start_it = std::lower_bound(offsets.begin(), offsets.end(), start);
        auto end_it = std::lower_bound(offsets.begin(), offsets.end(), end);
        if (start_it == offsets.end() || end_it == offsets.end()) {
            continue;
        }

        // We need to go one line back unless we're at the beginning of the line.
        if (*start_it > start) {
            --start_it;
        }
        if (*end_it > end) {
            --end_it;
        }

        const size_t start_line = std::distance(offsets.begin(), start_it);
        const int64_t start_column = int64_t(start) - int64_t(*start_it);

        const size_t end_line = std::distance(offsets.begin(), end_it);
        const int64_t end_column = int64_t(end) - int64_t(*end_it);

        [invocation.buffer.selections
            addObject:[[XCSourceTextRange alloc]
                          initWithStart:XCSourceTextPositionMake(start_line, start_column)
                                    end:XCSourceTextPositionMake(end_line, end_column)]];
    }

    // If we could not recover the selection, place the cursor at the beginning of the file.
    if (!invocation.buffer.selections.count) {
        [invocation.buffer.selections
            addObject:[[XCSourceTextRange alloc] initWithStart:XCSourceTextPositionMake(0, 0)
                                                           end:XCSourceTextPositionMake(0, 0)]];
    }

    completionHandler(nil);
}

@end
