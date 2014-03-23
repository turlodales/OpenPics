//
//  OPImageManager.m
//  OpenPics
//
//  Created by PJ Gray on 4/6/13.
//
// Copyright (c) 2013 Say Goodnight Software
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "OPImageManager.h"
#import "UIImageView+Hourglass.h"
#import "TMCache.h"
#import "OPImageItem.h"
#import "NSString+MD5.h"
#import "UIImage+Preload.h"
#import "AFHTTPRequestOperation.h"

@interface OPImageManager () {
    NSMutableDictionary* _imageOperations;
}

@end

@implementation OPImageManager

-(id) init {
    self = [super init];
    if (self) {
        _imageOperations = @{}.mutableCopy;
    }
    return self;
}

+ (NSOperationQueue *)imageRequestOperationQueue {
    static NSOperationQueue *_imageRequestOperationQueue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _imageRequestOperationQueue = [[NSOperationQueue alloc] init];
        _imageRequestOperationQueue.maxConcurrentOperationCount = NSOperationQueueDefaultMaxConcurrentOperationCount;
    });
    
    return _imageRequestOperationQueue;
}

- (void) cancelImageOperationAtIndexPath:(NSIndexPath*)indexPath {
    AFHTTPRequestOperation* operation = _imageOperations[indexPath];
    if (operation.isExecuting) {
        NSLog(@"Not visible, cancelling operation for row: %ld", (long)indexPath.row);
        [operation cancel];
    }
}

- (void) getImageWithRequestForItem:(OPImageItem*) item
                      withIndexPath:(NSIndexPath*) indexPath
                        withSuccess:(void (^)(UIImage* image))success
                        withFailure:(void (^)(void))failure {
    // if not found in cache, create request to download image
    NSURLRequest* request = [[NSURLRequest alloc] initWithURL:item.imageUrl];
    AFHTTPRequestOperation* operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = [AFImageResponseSerializer serializer];
    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
        UIImage* image = (UIImage*) responseObject;
        
        // if this item url is equal to the request one - continue (avoids flashyness on fast scrolling)
        if ([item.imageUrl.absoluteString isEqualToString:request.URL.absoluteString]) {
            
            // dispatch to a background thread for preloading
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                
                // uses category - will check for assocaited object
                UIImage* preloadedImage = image.preloadedImage;
                
                // set the loaded object to the cache
                [[TMCache sharedCache] setObject:preloadedImage forKey:item.imageUrl.absoluteString.MD5String];
                
                if (success) {
                    success(preloadedImage);
                }
            });
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (!operation.isCancelled) {
            NSLog(@"error getting image");
            if (failure) {
                failure();
            }
        }
    }];
    _imageOperations[indexPath] = operation;
    [[[self class] imageRequestOperationQueue] addOperation:operation];
}

- (void) getImageForItem:(OPImageItem*) item
           withIndexPath:(NSIndexPath*) indexPath
             withSuccess:(void (^)(UIImage* image))success
             withFailure:(void (^)(void))failure {
    // Then, dispatch async to another thread to check the cache for this image (might read from disk which is slow while scrolling
    
    // This was causing weird behavior, when quickly scrolling down a bunch of pages, then back to top  almost like it was deadlocking and not going into this dispatch_async
    //
    // just commenting this all out for now.   below is the other way, which causes
    // unbutteryness during fast scrolling, cause it is reading from disk for cached
    // images.
//    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
//        __block UIImage* cachedImage = [[TMCache sharedCache] objectForKey:item.imageUrl.absoluteString.MD5String];
//        dispatch_async(dispatch_get_main_queue(), ^{
//            if (cachedImage) {
//                cachedImage = cachedImage.preloadedImage;
//                if (success) {
//                    success(cachedImage);
//                }
//            } else {
//                [self getImageWithRequestForItem:item withIndexPath:indexPath withSuccess:success withFailure:failure];
//            }
//        });
//    });
    
    UIImage* cachedImage = [[TMCache sharedCache] objectForKey:item.imageUrl.absoluteString.MD5String];
    if (cachedImage) {
        cachedImage = cachedImage.preloadedImage;
        if (success) {
            success(cachedImage);
        }
    } else {
        [self getImageWithRequestForItem:item withIndexPath:indexPath withSuccess:success withFailure:failure];
    }

}

- (void) loadImageFromItem:(OPImageItem*) item toImageView:(UIImageView*) imageView atIndexPath:(NSIndexPath*) indexPath {
    [imageView fadeInHourglassWithCompletion:^{
        [self getImageForItem:item withIndexPath:indexPath withSuccess:^(UIImage *image) {
// if this cell is currently visible, continue drawing - this is for when scrolling fast (avoids flashyness)
            if (self.delegate) {
                if ([self.delegate isVisibileIndexPath:indexPath]) {
                    // then dispatch back to the main thread to set the image
                    dispatch_async(dispatch_get_main_queue(), ^{
                        
                        // fade out the hourglass image
                        [UIView animateWithDuration:0.25 animations:^{
                            imageView.alpha = 0.0;
                        } completion:^(BOOL finished) {
#warning AspectFit or fill?
                            imageView.contentMode = UIViewContentModeScaleAspectFill;
                            imageView.image = image;
                            
                            // fade in image
                            [UIView animateWithDuration:0.5 animations:^{
                                imageView.alpha = 1.0;
                            }];
                            
                            //if we have no size information yet, save the information in item, and force a re-layout
                            if (!item.size.height) {
                                item.size = image.size;
                                [self.delegate invalidateLayout];
                            }
                        }];
                    });
                }
            }
        } withFailure:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{
                    imageView.alpha = 0.0;
                } completion:^(BOOL finished) {
                    imageView.image = [UIImage imageNamed:@"image_cancel"];
                    [UIView animateWithDuration:0.5 animations:^{
                        imageView.alpha = 1.0;
                    }];
                }];
            });
        }];
    }];    
}

@end
