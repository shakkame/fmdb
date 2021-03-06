//
//  FMDatabaseQueue.m
//  fmdb
//
//  Created by August Mueller on 6/22/11.
//  Copyright 2011 Flying Meat Inc. All rights reserved.
//

#import "FMDatabaseQueue.h"
#import "FMDatabase.h"
#import "FMDatabaseLogger.h"

#ifdef FMDB_USE_LUMBERJACK
static const int ddLogLevel = LOG_LEVEL_VERBOSE;
#endif

/*
 
 Note: we call [self retain]; before using dispatch_sync, just incase 
 FMDatabaseQueue is released on another thread and we're in the middle of doing
 something in dispatch_sync
 
 */


@implementation FMDatabaseQueue

@synthesize path = _path;

+ (instancetype)databaseQueueWithPath:(NSString*)aPath {
    
    FMDatabaseQueue *q = [[self alloc] initWithPath:aPath];
    
    FMDBAutorelease(q);
    
    return q;
}

- (instancetype)initWithPath:(NSString*)aPath {
    
    self = [super init];
    
    if (self != nil) {
        
        _db = [FMDatabase databaseWithPath:aPath];
        FMDBRetain(_db);
        
        if (![_db open]) {
            DDLogError(@"Could not create database queue for path %@", aPath);
            FMDBRelease(self);
            return 0x00;
        }
        
        _path = FMDBReturnRetained(aPath);
        
        _dbQueueTag = &_dbQueueTag;
        _queue = dispatch_queue_create([[NSString stringWithFormat:@"fmdb.%@", self] UTF8String], NULL);
        dispatch_queue_set_specific(_queue, _dbQueueTag, _dbQueueTag, NULL);
    }
    
    return self;
}

- (void)dealloc {
    
    FMDBRelease(_db);
    FMDBRelease(_path);
    
    if (_queue) {
        FMDBDispatchQueueRelease(_queue);
        _queue = 0x00;
    }
#if ! __has_feature(objc_arc)
    [super dealloc];
#endif
}

- (void)close {
    FMDBRetain(self);
    
    dispatch_block_t internalBlock =  ^{
        [_db close];
        FMDBRelease(_db);
        _db = 0x00;
        
    FMDBRelease(self);
    };
    
    if (dispatch_get_specific(_dbQueueTag)) {
        internalBlock();
    } else {
		dispatch_sync(_queue, internalBlock);
    }
}

- (FMDatabase*)database {
    if (!_db) {
        _db = FMDBReturnRetained([FMDatabase databaseWithPath:_path]);
        
        if (![_db open]) {
            DDLogError(@"FMDatabaseQueue could not reopen database for path %@", _path);
            FMDBRelease(_db);
            _db  = 0x00;
            return 0x00;
        }
    }
    
    return _db;
}

- (void)inDatabase:(void (^)(FMDatabase *db))block async:(BOOL)async {
    FMDBRetain(self);
    
    dispatch_block_t internalBlock =  ^{
        FMDatabase *db = [self database];
        block(db);
        
        if ([db hasOpenResultSets]) {
            DDLogWarn(@"Warning: there is at least one open result set around after performing [FMDatabaseQueue inDatabase:]");
        }
    
    FMDBRelease(self);
    };
    
    if (async) {
        dispatch_async(_queue, internalBlock);
    } else {
        if (dispatch_get_specific(_dbQueueTag)) {
            internalBlock();
        } else {
            dispatch_sync(_queue, internalBlock);
        }
    }
}

- (void)inDatabase:(void (^)(FMDatabase *db))block {
    [self inDatabase:block async:NO];
}


- (void)beginTransaction:(BOOL)useDeferred withBlock:(void (^)(FMDatabase *db, BOOL *rollback))block {
    FMDBRetain(self);
        
    dispatch_block_t internalBlock =  ^{    
        BOOL shouldRollback = NO;
        
        if (useDeferred) {
            [[self database] beginDeferredTransaction];
        }
        else {
            [[self database] beginTransaction];
        }
        
        block([self database], &shouldRollback);
        
        if (shouldRollback) {
            [[self database] rollback];
        }
        else {
            [[self database] commit];
        }
    
    FMDBRelease(self);
    };
    
    if (dispatch_get_specific(_dbQueueTag))
		internalBlock();
	else
		dispatch_sync(_queue, internalBlock);
}

- (void)inDeferredTransaction:(void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:YES withBlock:block];
}

- (void)inTransaction:(void (^)(FMDatabase *db, BOOL *rollback))block {
    [self beginTransaction:NO withBlock:block];
}

#if SQLITE_VERSION_NUMBER >= 3007000
- (NSError*)inSavePoint:(void (^)(FMDatabase *db, BOOL *rollback))block {
    
    static unsigned long savePointIdx = 0;
    __block NSError *err = 0x00;
    FMDBRetain(self);

    dispatch_block_t internalBlock =  ^{
        
        NSString *name = [NSString stringWithFormat:@"savePoint%ld", savePointIdx++];
        
        BOOL shouldRollback = NO;
        
        if ([[self database] startSavePointWithName:name error:&err]) {
            
            block([self database], &shouldRollback);
            
            if (shouldRollback) {
                [[self database] rollbackToSavePointWithName:name error:&err];
            }
            else {
                [[self database] releaseSavePointWithName:name error:&err];
            }
            
        }
        
    FMDBRelease(self);
    };

    if (dispatch_get_specific(_dbQueueTag))
        internalBlock();
	else
		dispatch_sync(_queue, internalBlock);
    
    return err;
}
#endif

@end
