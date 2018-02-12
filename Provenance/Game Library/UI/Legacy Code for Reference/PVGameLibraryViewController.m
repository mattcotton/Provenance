//
//  PVGameLibraryViewController.m
//  Provenance
//
//  Created by James Addyman on 07/04/2013.
//  Copyright (c) 2013 JamSoft. All rights reserved.
//

#import "PVAppDelegate.h"
#import "PVGameImporter.h"
#import "PVGameLibraryViewController.h"
#import "PVEmulatorViewController.h"
#import "UIView+FrameAdditions.h"
#import "PVDirectoryWatcher.h"
#import "PVGame.h"
#import "PVRecentGame.h"
#import "UIActionSheet+BlockAdditions.h"
#import "PVEmulatorConfiguration.h"
#if !TARGET_OS_TV
    #import <AssetsLibrary/AssetsLibrary.h>
	#import <SafariServices/SafariServices.h>
    #import "PVSettingsViewController.h"
#else
#import "PVGame+Sizing.h"
#endif
#import "UIImage+Scaling.h"
#import "PVGameLibrarySectionHeaderView.h"
#import "MBProgressHUD.h"
#import "NSData+Hashing.h"
#import "PVSettingsModel.h"
#import "PVConflictViewController.h"
#import "PVWebServer.h"
#import "Reachability.h"
#import "PVControllerManager.h"
#import "PVEmulatorConstants.h"
#import "PVAppConstants.h"
#import "Provenance-Swift.h"

#define USE_IOS_11_SEARCHBAR 0

NSString * const PVGameLibraryHeaderView = @"PVGameLibraryHeaderView";
NSString * const kRefreshLibraryNotification = @"kRefreshLibraryNotification";

NSString * const PVRequiresMigrationKey = @"PVRequiresMigration";

#if TARGET_OS_TV
static const CGFloat CellWidth = 308.0;
@interface PVGameLibraryViewController ()
#else
@interface PVGameLibraryViewController () <SFSafariViewControllerDelegate>
#endif

@property (nonatomic, strong) PVDirectoryWatcher *watcher;
@property (nonatomic, strong) PVDirectoryWatcher *coverArtWatcher;
@property (nonatomic, strong) PVGameImporter *gameImporter;
@property (nonatomic, strong) UICollectionView *collectionView;
#if !TARGET_OS_TV
@property (nonatomic, strong) UIToolbar *renameToolbar;
#endif
@property (nonatomic, strong) UIView *renameOverlay;
@property (nonatomic, strong) UITextField *renameTextField;
@property (nonatomic, strong) PVGame *gameToRename;
@property (nonatomic, strong) PVGame *gameForCustomArt;
#if !TARGET_OS_TV
@property (nonatomic, strong) ALAssetsLibrary *assetsLibrary;
#endif

@property (nonatomic, strong) NSDictionary *gamesInSections;
@property (nonatomic, strong) NSArray *sectionInfo;
@property (nonatomic, strong) RLMResults *searchResults;

@property (nonatomic, weak) IBOutlet UITextField *searchField;

@property (nonatomic, assign) BOOL initialAppearance;

@property (nonatomic, assign) BOOL mustRefreshDataSource;

@end

@interface PVGameLibraryViewController () <UISearchResultsUpdating>
@end

@implementation PVGameLibraryViewController

static NSString *_reuseIdentifier = @"PVGameLibraryCollectionViewCell";

#pragma mark - Lifecycle

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if ((self = [super initWithCoder:aDecoder]))
    {
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{PVRequiresMigrationKey : @(YES)}];
        
#if USE_IOS_11_SEARCHBAR
#if !TARGET_OS_TV
        if (@available(iOS 11.0, *)) {
            // Hide the pre iOS 11 search bar
            self.navigationItem.titleView = nil;
            
            // Navigation bar large titles
            self.navigationController.navigationBar.prefersLargeTitles = NO;
            self.navigationItem.title = nil;

            // Create a search contorller
            UISearchController *searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
            searchController.searchBar.placeholder = @"Search";
            searchController.searchResultsUpdater = self;
            self.navigationItem.hidesSearchBarWhenScrolling = YES;
            self.navigationItem.searchController = searchController;
        }
#endif
#endif
    }
    
    return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleAppDidBecomeActive:(NSNotification *)note
{
    [self loadGameFromShortcut];
}

- (void)viewDidLoad
{
	[super viewDidLoad];

    self.initialAppearance = YES;

    [self setDefinesPresentationContext:YES];
    
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(handleCacheEmptied:)
												 name:PVMediaCacheWasEmptiedNotification
											   object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleArchiveInflationFailed:)
                                                 name:PVArchiveInflationFailedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRefreshLibrary:)
                                                 name:kRefreshLibraryNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleTextFieldDidChange:)
                                                 name:UITextFieldTextDidChangeNotification
                                               object:self.searchField];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAppDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserverForName:kInterfaceDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        [self.collectionView.collectionViewLayout invalidateLayout];
        [self.collectionView reloadData];
    }];
	
	[PVEmulatorConfiguration sharedInstance]; //load the config file
		
	[self setTitle:@"Library"];
    
	UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
	[layout setSectionInset:UIEdgeInsetsMake(20, 0, 20, 0)];
    
	self.collectionView = [[UICollectionView alloc] initWithFrame:[self.view bounds] collectionViewLayout:layout];
	[self.collectionView setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
	[self.collectionView setDataSource:self];
	[self.collectionView setDelegate:self];
	[self.collectionView setBounces:YES];
	[self.collectionView setAlwaysBounceVertical:YES];
	[self.collectionView setDelaysContentTouches:NO];
    [self.collectionView setKeyboardDismissMode:UIScrollViewKeyboardDismissModeInteractive];
    [self.collectionView registerClass:[PVGameLibrarySectionHeaderView class]
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:PVGameLibraryHeaderView];
#if TARGET_OS_TV
    [self.collectionView setContentInset:UIEdgeInsetsMake(40, 80, 40, 80)];
#endif
	[[self view] addSubview:self.collectionView];
    
	UILongPressGestureRecognizer *longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressRecognized:)];
	[self.collectionView addGestureRecognizer:longPressRecognizer];
	
	[self.collectionView registerClass:[PVGameLibraryCollectionViewCell class] forCellWithReuseIdentifier:_reuseIdentifier];
    
    if ([[NSUserDefaults standardUserDefaults] boolForKey:PVRequiresMigrationKey])
    {
        [self migrateLibrary];
    }
    else
    {
        [self setUpGameLibrary];
    }

    [self loadGameFromShortcut];
    
    [self becomeFirstResponder];
}

- (void)loadGameFromShortcut
{
    PVAppDelegate *appDelegate = (PVAppDelegate *)[[UIApplication sharedApplication] delegate];
    
    if ([appDelegate shortcutItemMD5])
    {
        [self loadRecentGameFromShortcut:[appDelegate shortcutItemMD5]];
        [appDelegate setShortcutItemMD5:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	NSArray *indexPaths = [self.collectionView indexPathsForSelectedItems];
	[indexPaths enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		[self.collectionView deselectItemAtIndexPath:obj animated:YES];
	}];

//    if (self.mustRefreshDataSource) {
        [self fetchGames];
        [self.collectionView reloadData];
//    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    [PVControllerManager sharedManager];

    if (self.initialAppearance)
    {
        self.initialAppearance = NO;
#if TARGET_OS_TV
        UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
        [cell setNeedsFocusUpdate];
        [cell updateFocusIfNeeded];
#endif
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
	return UIInterfaceOrientationMaskAll;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    if ([[segue identifier] isEqualToString:@"SettingsSegue"])
    {
#if !TARGET_OS_TV
        [(PVSettingsViewController *)[[segue destinationViewController] topViewController] setGameImporter:self.gameImporter];
#endif
        
        // Refresh table view data source when back from settings
        self.mustRefreshDataSource = YES;
    }
}

#if !TARGET_OS_TV
// Show web server (stays on)
- (void)showServer {
    NSURL *ipURL = [NSURL URLWithString:PVWebServer.sharedInstance.URLString];
	SFSafariViewController *safariVC = [[SFSafariViewController alloc]initWithURL:ipURL entersReaderIfAvailable:NO];
	safariVC.delegate = self;
	[self presentViewController:safariVC animated:YES completion:nil];
}

- (void)safariViewController:(SFSafariViewController *)controller didCompleteInitialLoad:(BOOL)didLoadSuccessfully {
	// Load finished
}

// Dismiss and shut down web server
- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
	// Done button pressed
	[self.navigationController popViewControllerAnimated:YES];
	[[PVWebServer sharedInstance] stopServers];
}
#endif

// Show "Web Server Active" alert view
- (void)showServerActiveAlert {
	NSString *message = [NSString stringWithFormat: @"Upload/Download ROMs,\nsaves and cover art at:\n"];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"Web Server Active"
																   message: message
															preferredStyle:UIAlertControllerStyleAlert];
	UITextView *ipField = [[UITextView alloc] initWithFrame:CGRectMake(20,71,231,70)];
	ipField.backgroundColor = [UIColor clearColor];
	ipField.textAlignment = NSTextAlignmentCenter;
	ipField.font = [UIFont systemFontOfSize:13];
	ipField.textColor = [UIColor grayColor];
    NSString* ipFieldText = [NSString stringWithFormat:@"%@\nWebDav: %@", PVWebServer.sharedInstance.URLString, PVWebServer.sharedInstance.WebDavURLString];
    [ipField setText:ipFieldText];
	[ipField setUserInteractionEnabled:NO];
	[alert.view addSubview:ipField];

	UITextView *importNote = [[UITextView alloc] initWithFrame:CGRectMake(2,160,267,44)];
	[importNote setUserInteractionEnabled:NO];
	importNote.font = [UIFont boldSystemFontOfSize:12];
	importNote.textColor = [UIColor whiteColor];
	importNote.textAlignment = NSTextAlignmentCenter;
	importNote.backgroundColor = [UIColor colorWithWhite:.2 alpha:.3];
    importNote.text = @"Check the wiki for information\nabout Importing ROMs.";
	importNote.layer.shadowOpacity = 0.8;
	importNote.layer.shadowRadius = 3.0;
    importNote.layer.cornerRadius = 8.0;
	importNote.layer.shadowColor = [UIColor colorWithWhite:.2 alpha:.7].CGColor;
	importNote.layer.shadowOffset = CGSizeMake(0.0, 0.0);
	[alert.view addSubview:importNote];

	[alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
		[[PVWebServer sharedInstance] stopServers];
	}]];
#if !TARGET_OS_TV
	UIAlertAction *viewAction = [UIAlertAction actionWithTitle: @"View" style: UIAlertActionStyleDefault handler: ^(UIAlertAction *action)
	{
		[self showServer];
	}];
	[alert addAction:viewAction];
#endif
	[self presentViewController:alert animated:YES completion:NULL];
	
}

#pragma mark - Filesystem Helpers

- (IBAction)getMoreROMs
{
    Reachability *reachability = [Reachability reachabilityForInternetConnection];
    [reachability startNotifier];

    NetworkStatus status = [reachability currentReachabilityStatus];

    if (status != ReachableViaWiFi)
    {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"Unable to start web server!"
                                                                       message: @"Your device needs to be connected to a network to continue!"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        }]];
        [self presentViewController:alert animated:YES completion:NULL];
    } else {
        // connected via wifi, let's continue

        // start web transfer service
        if([[PVWebServer sharedInstance] startServers]) {
            //show alert view
            [self showServerActiveAlert];
        } else {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"Unable to start web server!"
                                                                           message: @"Check your network connection or that something isn't already running on required ports 80 & 81"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            }]];
            [self presentViewController:alert animated:YES completion:NULL];
        }
    }
}

#pragma mark - Game Library Management

- (void)migrateLibrary
{
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:self.view animated:YES];
    [hud setUserInteractionEnabled:NO];
    [hud setMode:MBProgressHUDModeIndeterminate];
    [hud setLabelText:@"Migrating Game Library"];
    [hud setDetailsLabelText:@"Please be patient, this may take a while..."];
    
    NSString *libraryPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSError *error = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:[libraryPath stringByAppendingPathComponent:@"PVGame.sqlite"] error:&error])
    {
        DLog(@"Unable to delete PVGame.sqlite because %@", [error localizedDescription]);
    }
    if (![[NSFileManager defaultManager] removeItemAtPath:[libraryPath stringByAppendingPathComponent:@"PVGame.sqlite-shm"] error:&error])
    {
        DLog(@"Unable to delete PVGame.sqlite-shm because %@", [error localizedDescription]);
    }
    if (![[NSFileManager defaultManager] removeItemAtPath:[libraryPath stringByAppendingPathComponent:@"PVGame.sqlite-wal"] error:&error])
    {
        DLog(@"Unable to delete PVGame.sqlite-wal because %@", [error localizedDescription]);
    }
    
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];
    
    if (![[NSFileManager defaultManager] createDirectoryAtPath:[config romsPath]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error])
    {
        DLog(@"Unable to create roms directory because %@", [error localizedDescription]);
        return; // dunno what else can be done if this fails
    }
    
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[config documentsPath] error:&error];
    if (!contents)
    {
        DLog(@"Unable to get contents of documents because %@", [error localizedDescription]);
    }
    
    for (NSString *path in contents)
    {
        NSString *fullPath = [[config documentsPath] stringByAppendingPathComponent:path];
        BOOL isDir = NO;
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];
        if (exists && !isDir && ![[path lowercaseString] containsString:@"realm"])
        {
            if (![[NSFileManager defaultManager] moveItemAtPath:fullPath
                                                         toPath:[[config romsPath] stringByAppendingPathComponent:path]
                                                          error:&error])
            {
                DLog(@"Unable to move %@ to %@ because %@", fullPath, [[config romsPath] stringByAppendingPathComponent:path], [error localizedDescription]);
            }
        }
    }
    
    [hud hide:YES];
    
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:PVRequiresMigrationKey];
    
    [self setUpGameLibrary];
    [self.gameImporter startImportForPaths:[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[config romsPath] error:&error]];
}

- (void)setUpGameLibrary
{
    [self fetchGames];
    
    __weak typeof(self) weakSelf = self;
    
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

    self.gameImporter = [[PVGameImporter alloc] initWithCompletionHandler:^(BOOL encounteredConflicts) {
        if (encounteredConflicts)
        {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Oops!"
                                                                           message:@"There was a conflict while importing your game."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Let's go fix it!"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *action) {
                                                        PVConflictViewController *conflictViewController = [[PVConflictViewController alloc] initWithGameImporter:weakSelf.gameImporter];
                                                        UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:conflictViewController];
                                                        [weakSelf presentViewController:navController animated:YES completion:NULL];
                                                    }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Nah, I'll do it later..."
                                                      style:UIAlertActionStyleCancel
                                                    handler:NULL]];
            [weakSelf presentViewController:alert animated:YES completion:NULL];
        }
    }];
    [self.gameImporter setImportStartedHandler:^(NSString *path) {
        MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:weakSelf.view animated:YES];
        [hud setUserInteractionEnabled:NO];
        [hud setMode:MBProgressHUDModeIndeterminate];
        [hud setLabelText:[NSString stringWithFormat:@"Importing %@", [path lastPathComponent]]];
    }];
    [self.gameImporter setFinishedImportHandler:^(NSString *md5, BOOL modified) {
        // This callback is always called,
        // even if the started handler was not called because it didn't require a refresh.
        [weakSelf finishedImportingGameWithMD5:md5 modified:modified];
    }];
    [self.gameImporter setFinishedArtworkHandler:^(NSString *url) {
        [weakSelf finishedDownloadingArtworkForURL:url];
    }];
    
    NSArray *existingFiles = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[config romsPath]
                                                                                 error:nil];
    [self.gameImporter startImportForPaths:existingFiles];
    
    self.watcher = [[PVDirectoryWatcher alloc] initWithPath:[config romsPath]
                                   extractionStartedHandler:^(NSString *path) {
                                       MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];
                                       if (!hud)
                                       {
                                           hud = [MBProgressHUD showHUDAddedTo:weakSelf.view animated:YES];
                                       }
                                       [hud setUserInteractionEnabled:NO];
                                       [hud setMode:MBProgressHUDModeAnnularDeterminate];
                                       [hud setProgress:0];
#if TARGET_OS_TV
                                       NSString *label = [NSString stringWithFormat:@"Extracting Archive: %@", path.lastPathComponent];
#else
                                       NSString *label = @"Extracting Archive...";
#endif
                                       [hud setLabelText:label];
                                   }
                                   extractionUpdatedHandler:^(NSString *path, NSInteger entryNumber, NSInteger total, float progress) {
                                       MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];
                                       [hud setUserInteractionEnabled:NO];
                                       [hud setMode:MBProgressHUDModeAnnularDeterminate];
                                       [hud setProgress:progress];
#if TARGET_OS_TV
                                       NSString *label = [NSString stringWithFormat:@"Extracting Archive: %@", path.lastPathComponent];
#else
                                       NSString *label = @"Extracting Archive...";
#endif
                                       [hud setLabelText:label];
                                   }
                                  extractionCompleteHandler:^(NSArray *paths) {
                                      MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];
                                      [hud setUserInteractionEnabled:NO];
                                      [hud setMode:MBProgressHUDModeAnnularDeterminate];
                                      [hud setProgress:1];
                                      [hud setLabelText:@"Extraction Complete!"];
                                      [hud hide:YES afterDelay:0.5];
                                      [weakSelf.gameImporter startImportForPaths:paths];
                                  }];
    [self.watcher startMonitoring];

    self.coverArtWatcher = [[PVDirectoryWatcher alloc] initWithPath:config.coverArtPath extractionStartedHandler:^(NSString *path) {
        MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];

        if (!hud) {
            hud = [MBProgressHUD showHUDAddedTo:weakSelf.view animated:YES];
        }

        [hud setUserInteractionEnabled:NO];
        [hud setMode:MBProgressHUDModeAnnularDeterminate];
        [hud setProgress:0];
        [hud setLabelText:@"Extracting Archive…"];
    } extractionUpdatedHandler:^(NSString *path, NSInteger entryNumber, NSInteger total, float progress) {
        MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];
        [hud setProgress:progress];
    } extractionCompleteHandler:^(NSArray *paths) {
        MBProgressHUD *hud = [MBProgressHUD HUDForView:weakSelf.view];
        [hud setProgress:1];
        [hud setLabelText:@"Extraction Complete!"];
        [hud hide:YES afterDelay:0.5];

        for (NSString *imageFilepath in paths) {
            NSString *imageFullPath = [config.coverArtPath stringByAppendingPathComponent:imageFilepath];
            PVGame *game = [PVGameImporter importArtworkFromPath:imageFullPath];
            NSArray *indexPaths = [weakSelf indexPathsForGameWithMD5Hash:game.md5Hash];
            [weakSelf.collectionView reloadItemsAtIndexPaths:indexPaths];
        }
    }];

    [self.coverArtWatcher startMonitoring];
    
    NSArray *systems = [[PVEmulatorConfiguration sharedInstance] availableSystemIdentifiers];
    for (NSString *systemID in systems)
    {
        NSString *systemDir = [[config documentsPath] stringByAppendingPathComponent:systemID];
        if ([[NSFileManager defaultManager] fileExistsAtPath:systemDir])
        {
            NSError *error = nil;
            NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:systemDir error:&error];
            dispatch_async([self.gameImporter serialImportQueue], ^{
                [self.gameImporter getRomInfoForFilesAtPaths:contents userChosenSystem:systemID];
                if ([self.gameImporter completionHandler])
                {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.gameImporter completionHandler]([self.gameImporter encounteredConflicts]);
                    });
                }
            });
        }
    }
}

- (void)fetchGames
{
    [RomDatabase.sharedInstance refresh];

    // Favorite Games
    RLMResults *allSortedGames = [RomDatabase.sharedInstance allGamesWithSortedByKey:@"title" ascending:YES];
    NSMutableArray *favoriteGames = [[NSMutableArray alloc] init];
    for (PVGame *game in allSortedGames) {
        if (game.isFavorite) {
            [favoriteGames addObject:game];
        }
    }

    // Recent games
    NSMutableArray *recentGames = [[NSMutableArray alloc] init];
    if ([[PVSettingsModel sharedInstance] showRecentGames]) {
        RLMResults *recents = [PVRecentGame allObjects];
        for (PVRecentGame *recentGame in [recents sortedResultsUsingProperty:@"lastPlayedDate" ascending:NO]) {
            PVGame *game = recentGame.game;
            if (game) {
                [recentGames addObject:game];
            }
        }
    }

    // Games by system
    NSMutableDictionary *tempSections = [NSMutableDictionary dictionary];
    for (PVGame *game in allSortedGames)
    {
        NSString *systemID = [game systemIdentifier];
        NSMutableArray *games = [tempSections objectForKey:systemID];
        if (!games)
        {
            games = [NSMutableArray array];
        }
        
        [games addObject:game];
        [tempSections setObject:games forKey:systemID];
    }

    NSMutableArray *sectionInfo = [[[tempSections allKeys] sortedArrayUsingSelector:@selector(compare:)] mutableCopy];

    // Check if recent games should be added to menu
    if (recentGames.count>0) {
        NSString *key = @"recent";
        [sectionInfo insertObject:key atIndex:0];
        [tempSections setObject:recentGames forKey:key];
    }
    
    // Check if favorite games should be added to menu
    if (favoriteGames.count > 0) {
        NSString *key = @"favorite";
        [sectionInfo insertObject:key atIndex:0];
        [tempSections setObject:favoriteGames forKey:key];
    }
    
    // Set data source
    self.gamesInSections = tempSections;
    self.sectionInfo = sectionInfo;
    
    self.mustRefreshDataSource = NO;
}

- (void)finishedImportingGameWithMD5:(NSString *)md5 modified:(BOOL)modified;
{
    MBProgressHUD *hud = [MBProgressHUD HUDForView:self.view];
    [hud hide:YES];

    // Only refresh the whole collection if game was modified.
    if (modified) {
        [self fetchGames];
        [self.collectionView reloadData];
    }

    // code below is simply to animate updates... currently crashy

//    NSArray *oldSectionInfo = [self.sectionInfo copy];
//    NSIndexPath *indexPath = [self indexPathForGameWithMD5Hash:md5];
//    [self fetchGames];
//    if (indexPath)
//    {
//        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
//    }
//    else
//    {
//        indexPath = [self indexPathForGameWithMD5Hash:md5];
//        PVGame *game = [[PVGame objectsInRealm:self.realm where:@"md5Hash == %@", md5] firstObject];
//        NSString *systemID = [game systemIdentifier];
//        __block BOOL needToInsertSection = YES;
//        [self.sectionInfo enumerateObjectsUsingBlock:^(NSString *section, NSUInteger sectionIndex, BOOL *stop) {
//            if ([systemID isEqualToString:section])
//            {
//                needToInsertSection = NO;
//                *stop = YES;
//            }
//        }];
//        
//        [self.collectionView performBatchUpdates:^{
//            if (needToInsertSection)
//            {
//                [self.collectionView insertSections:[NSIndexSet indexSetWithIndex:[indexPath section]]];
//            }
//            [self.collectionView insertItemsAtIndexPaths:@[indexPath]];
//        } completion:^(BOOL finished) {
//        }];
//    }
}

- (void)finishedDownloadingArtworkForURL:(NSString *)url
{
    NSIndexPath *indexPath = [self indexPathForGameWithURL:url];
    if (indexPath)
    {
        [self.collectionView reloadItemsAtIndexPaths:@[indexPath]];
    }
}

- (NSArray *)indexPathsForGameWithMD5Hash:(NSString *)md5Hash
{
    NSMutableArray *indexPaths = [[NSMutableArray alloc] init];

    if (self.searchResults)
    {
        for (PVGame *game in self.searchResults) {
            if ([[game md5Hash] isEqualToString:md5Hash])
            {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[self.searchResults indexOfObject:game] inSection:0];
                [indexPaths addObject:indexPath];
            }
        }
    }
    else
    {
        [self.sectionInfo enumerateObjectsUsingBlock:^(NSString *sectionKey, NSUInteger sectionIndex, BOOL *sectionStop) {
            NSArray *games = self.gamesInSections[sectionKey];
            [games enumerateObjectsUsingBlock:^(PVGame *game, NSUInteger gameIndex, BOOL *gameStop) {
                if ([[game md5Hash] isEqualToString:md5Hash])
                {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:gameIndex inSection:sectionIndex];
                    [indexPaths addObject:indexPath];
                }
            }];
        }];
    }

    return indexPaths;
}

- (NSIndexPath *)indexPathForGameWithURL:(NSString *)url
{
    NSIndexPath *indexPath = nil;
    __block NSInteger section = NSNotFound;
    __block NSInteger item = NSNotFound;
    
    [self.sectionInfo enumerateObjectsUsingBlock:^(NSString *sectionKey, NSUInteger sectionIndex, BOOL *sectionStop) {
        NSArray *games = self.gamesInSections[sectionKey];
        [games enumerateObjectsUsingBlock:^(PVGame *game, NSUInteger gameIndex, BOOL *gameStop) {
            if ([[game originalArtworkURL] isEqualToString:url] ||
                [[game customArtworkURL] isEqualToString:url])
            {
                section = sectionIndex;
                item = gameIndex;
                *gameStop = YES;
                *sectionStop = YES;
            }
        }];
    }];
    
    if ((section != NSNotFound) && (item != NSNotFound))
    {
        indexPath = [NSIndexPath indexPathForItem:item inSection:section];
    }
    
    return indexPath;
}

- (void)handleCacheEmptied:(NSNotificationCenter *)notification
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        RomDatabase* database = RomDatabase.sharedInstance;
        [database refresh];

        for (PVGame *game in database.allGames)
        {
            [database writeTransactionAndReturnError:nil
                                                    :^{
                                                        [game setCustomArtworkURL:@""];
                                                    }];
            
            NSString *originalArtworkURL = [game originalArtworkURL];
            [weakSelf.gameImporter getArtworkFromURL:originalArtworkURL];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [RomDatabase.sharedInstance refresh];
            [weakSelf fetchGames];
        });

    });
}

- (void)handleArchiveInflationFailed:(NSNotification *)note
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to extract archive"
                                                                   message:@"There was a problem extracting the archive. Perhaps the download was corrupt? Try downloading it again."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:NULL]];
    [self presentViewController:alert animated:YES completion:NULL];
}

- (void)handleRefreshLibrary:(NSNotification *)note
{
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

    NSString *documentsPath = [config documentsPath];
    NSMutableArray *romPaths = [NSMutableArray array];

    RomDatabase* database = RomDatabase.sharedInstance;
    
    for (PVGame *game in database.allGames)
    {
        NSString *path = [documentsPath stringByAppendingPathComponent:[game romPath]];
        [romPaths addObject:path];
    }

    [database deleteAllObjectsAndReturnError:nil];
    [self fetchGames];
    [self.collectionView reloadData];

    [self setUpGameLibrary];

//    dispatch_async([self.gameImporter serialImportQueue], ^{
//        [self.gameImporter getRomInfoForFilesAtPaths:romPaths userChosenSystem:nil];
//        if ([self.gameImporter completionHandler])
//        {
//            [self.gameImporter completionHandler]([self.gameImporter encounteredConflicts]);
//        }
//    });
}

-(void)createBiosDirectoryAtPath:(NSString*)biosPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:biosPath]) {
        NSError *error;
        BOOL success = [fm createDirectoryAtPath:biosPath
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&error];
        if (!success) {
            NSLog(@"Error creating BIOS dir: %@", error.localizedDescription);
        }
    }
}

typedef NSDictionary<NSString*,NSString*> BiosDictionary;

- (BOOL)canLoadGame:(PVGame *)game
{
    BOOL canLoad = YES;
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

    NSDictionary *system = [[PVEmulatorConfiguration sharedInstance] systemForIdentifier:[game systemIdentifier]];
    BOOL requiresBIOS = [system[PVRequiresBIOSKey] boolValue];
    if (requiresBIOS)
    {
        NSArray<BiosDictionary*> *biosNames = system[PVBIOSNamesKey];
        NSString *biosPath = [config BIOSPathForSystemID:[game systemIdentifier]];
        NSError *error = nil;
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:biosPath error:&error];
        if (!contents)
        {
            DLog(@"Unable to get contents of %@ because %@", biosPath, [error localizedDescription]);
            canLoad = NO;
        }
        
        for (BiosDictionary* bios in biosNames)
        {
            if (![contents containsObject:bios[@"Name"]])
            {
                canLoad = NO;
                break;
            }
        }
    
        if (canLoad == NO)
        {
            // Create missing BIOS directory to help user out
            [self createBiosDirectoryAtPath:biosPath];
            
            NSMutableString *biosString = [NSMutableString string];
            for (BiosDictionary* bios in biosNames)
            {
                NSString *name = bios[@"Name"];
                [biosString appendString:[NSString stringWithFormat:@"%@", name]];
                if (biosNames.lastObject != bios)
                {
                    [biosString appendString:@",\n"];
                }
            }
            
            NSString *message = [NSString stringWithFormat:@"%@ requires BIOS files to run games. Ensure the following files are inside Documents/BIOS/%@/\n\n%@", system[PVShortSystemNameKey], system[PVSystemIdentifierKey], biosString];
            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Missing BIOS Files"
                                                                                     message:message
                                                                              preferredStyle:UIAlertControllerStyleAlert];
            [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:NULL]];
            [self presentViewController:alertController animated:YES completion:NULL];
        }
    }

//    if ([self.presentedViewController isKindOfClass:[PVEmulatorViewController class]])
//    {
//        canLoad = NO;
//    }

    return canLoad;
}

- (void)loadGame:(PVGame *)game
{
    void (^loadGame)(void) = ^void(void) {
        PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

        if ([self canLoadGame:game])
        {
            PVEmulatorViewController *emulatorViewController = [[PVEmulatorViewController alloc] initWithGame:game];
            [emulatorViewController setBatterySavesPath:[config batterySavesPathForROM:[[config romsPath] stringByAppendingPathComponent:[game romPath]]]];
            [emulatorViewController setSaveStatePath:[config saveStatePathForROM:[[config romsPath] stringByAppendingPathComponent:[game romPath]]]];
            [emulatorViewController setBIOSPath:[config BIOSPathForSystemID:[game systemIdentifier]]];
			[emulatorViewController setSystemID:[game systemIdentifier]];
            [emulatorViewController setModalTransitionStyle:UIModalTransitionStyleCrossDissolve];

            [self presentViewController:emulatorViewController animated:YES completion:NULL];
             [[[PVControllerManager sharedManager] iCadeController] refreshListener];
            [self updateRecentGames:game];
        }
    };

    if (![[self presentedViewController] isKindOfClass:[PVEmulatorViewController class]])
    {
        loadGame();
    }
}

- (void)updateRecentGames:(PVGame *)game
{
    [RomDatabase.sharedInstance refresh];
    
    RLMResults *recents = [PVRecentGame allObjects];
    
    PVRecentGame *recentToDelete = [[PVRecentGame objectsWithPredicate:[NSPredicate predicateWithFormat:@"game.md5Hash == %@", [game md5Hash]]] firstObject];
    if (recentToDelete)
    {
        [RomDatabase.sharedInstance deleteWithObject:recentToDelete error:nil];
    }
    
    if ([recents count] >= PVMaxRecentsCount)
    {
        PVRecentGame *oldestRecent = [[recents sortedResultsUsingProperty:@"lastPlayedDate" ascending:NO] lastObject];
        
        [RomDatabase.sharedInstance deleteWithObject:oldestRecent error:nil];
    }
    
    PVRecentGame *newRecent = [[PVRecentGame alloc] initWithGame:game];
    
    [RomDatabase.sharedInstance addWithObject:newRecent error:nil];

    [self registerRecentGames:recents];
    
    self.mustRefreshDataSource = YES;
}

- (void)registerRecentGames:(RLMResults *)recents
{
#if !TARGET_OS_TV

    if (NSClassFromString(@"UIApplicationShortcutItem")) {

        NSMutableArray *shortcuts = [NSMutableArray array];
        RLMRealm *realm = [RLMRealm defaultRealm];
        
        RLMResults *sortedRecents = [recents sortedResultsUsingProperty:@"lastPlayedDate" ascending:NO];
        for (NSInteger i=0; i<sortedRecents.count && i<PVMaxRecentsShortcutCount; i++)
        {
            PVRecentGame *recentGame = [sortedRecents objectAtIndex:i];
        
            if ([recentGame game])
            {
                UIApplicationShortcutItem *shortcut = [[UIApplicationShortcutItem alloc] initWithType:@"kRecentGameShortcut"
                                                                                       localizedTitle:[[recentGame game] title]
                                                                                    localizedSubtitle:[[PVEmulatorConfiguration sharedInstance] nameForSystemIdentifier:[[recentGame game] systemIdentifier]]
                                                                                                 icon:nil
                                                                                             userInfo:@{@"PVGameHash": [[recentGame game] md5Hash]}];
                [shortcuts addObject:shortcut];
            }
            else
            {
                [realm beginWriteTransaction];
                [realm deleteObject:recentGame];
                [realm commitWriteTransaction];
            }
        }
        
        [[UIApplication sharedApplication] setShortcutItems:shortcuts];
        
    }
    
#endif
}

- (void)loadRecentGameFromShortcut:(NSString *)md5
{
    if ([md5 length])
    {
        PVRecentGame *recentGame = [[PVRecentGame objectsWithPredicate:[NSPredicate predicateWithFormat:@"game.md5Hash == %@", md5]] firstObject];
        PVGame *game = [recentGame game];
        [self loadGame:game];
    }
}

- (void)longPressRecognized:(UILongPressGestureRecognizer *)recognizer
{
    if ([recognizer state] == UIGestureRecognizerStateBegan)
    {
        __weak PVGameLibraryViewController *weakSelf = self;
        CGPoint point = [recognizer locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];

#if TARGET_OS_TV
        if (!indexPath)
        {
            indexPath = [self.collectionView indexPathForCell:(UICollectionViewCell *)[[UIScreen mainScreen] focusedView]];
        }
#endif

        if (!indexPath)
        {
            // no index path, we're buggered.
            return;
        }

        PVGame *game = [self gameAtIndexPath:indexPath];
        
        UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:nil
                                                                             message:nil
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
        if (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad)
        {
            UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
            [[actionSheet popoverPresentationController] setSourceView:cell];
            [[actionSheet popoverPresentationController] setSourceRect:[[self.collectionView layoutAttributesForItemAtIndexPath:indexPath] bounds]];
        }

        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Toggle Favorite"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
                                                          [weakSelf toggleFavoriteForGame:game];
                                                      }]];

        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Rename"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
                                                          [weakSelf renameGame:game];
                                                      }]];

#if !TARGET_OS_TV
        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Choose Custom Artwork"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
                                                          [weakSelf chooseCustomArtworkForGame:game];
                                                      }]];
        
        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Paste Custom Artwork"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
                                                          [weakSelf pasteCustomArtworkForGame:game];
                                                      }]];

        if ([[game originalArtworkURL] length] &&
            [[game originalArtworkURL] isEqualToString:[game customArtworkURL]] == NO)
        {
            [actionSheet addAction:[UIAlertAction actionWithTitle:@"Restore Original Artwork"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
                                                              [PVMediaCache deleteImageForKey:[game customArtworkURL]];
                                                              
                                                              [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
                                                                  [game setCustomArtworkURL:@""];
                                                              }];

                                                              NSString *originalArtworkURL = [game originalArtworkURL];
                                                              dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                                  [weakSelf.gameImporter getArtworkFromURL:originalArtworkURL];
                                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                                      NSArray *indexPaths = [self indexPathsForGameWithMD5Hash:[game md5Hash]];
                                                                      [weakSelf fetchGames];
                                                                      [weakSelf.collectionView reloadItemsAtIndexPaths:indexPaths];
                                                                  });
                                                              });
                                                          }]];
        }
#endif

#if TARGET_OS_TV
        [actionSheet setMessage:[NSString stringWithFormat:@"Options for %@", [game title]]];
#endif

        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@", [game title]]
                                                                           message:@"Any save states and battery saves will also be deleted, are you sure?"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Yes" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
                [weakSelf deleteGame:game];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"No" style:UIAlertActionStyleCancel handler:NULL]];
            [weakSelf presentViewController:alert animated:YES completion:NULL];
        }]];

        [actionSheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:NULL]];
        [weakSelf presentViewController:actionSheet animated:YES completion:NULL];
    }
}

- (void)toggleFavoriteForGame:(PVGame *)game {
    [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
        game.isFavorite = !game.isFavorite;
    }];

    [self fetchGames];
    [self.collectionView reloadData];
}

- (void)renameGame:(PVGame *)game
{
#if TARGET_OS_TV
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename"
                                                                   message:[NSString stringWithFormat:@"Enter a new name for %@", [game title]]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = [game title];
    }];
    
    __weak PVGameLibraryViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *title = [[alert.textFields firstObject] text];
        [weakSelf renameGame:game toTitle:title];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:alert animated:YES completion:NULL];
    
#else
    self.gameToRename = game;
    
    self.renameOverlay = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.renameOverlay setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    [self.renameOverlay setBackgroundColor:[UIColor colorWithWhite:0.0 alpha:0.3]];
    [self.renameOverlay setAlpha:0.0];
    [self.view addSubview:self.renameOverlay];
    
    [UIView animateWithDuration:0.3
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         [self.renameOverlay setAlpha:1.0];
                     }
                     completion:NULL];

    self.renameToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    [self.renameToolbar setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin];
    [self.renameToolbar setBarStyle:UIBarStyleBlack];
    
    self.renameTextField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width - 24, 30)];
    [self.renameTextField setAutoresizingMask:UIViewAutoresizingFlexibleWidth];
    [self.renameTextField setBorderStyle:UITextBorderStyleRoundedRect];
    [self.renameTextField setPlaceholder:[game title]];
    [self.renameTextField setText:[game title]];
    [self.renameTextField setKeyboardAppearance:UIKeyboardAppearanceAlert];
    [self.renameTextField setReturnKeyType:UIReturnKeyDone];
    [self.renameTextField setDelegate:self];
    
    UIBarButtonItem *textFieldItem = [[UIBarButtonItem alloc] initWithCustomView:self.renameTextField];
    
    [self.renameToolbar setItems:@[textFieldItem]];
    
    [self.renameToolbar setOriginY:self.view.bounds.size.height];
    [self.renameOverlay addSubview:self.renameToolbar];
    
    [self.navigationController.view addSubview:self.renameOverlay];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    
    [self.renameTextField becomeFirstResponder];
    [self.renameTextField selectAll:nil];
#endif
}

#if !TARGET_OS_TV
- (void)doneRenaming:(id)sender
{
    NSString *newTitle = [self.renameTextField text];
    
    [self renameGame:self.gameToRename toTitle:newTitle];
    
    self.gameToRename = nil;
    
    [UIView animateWithDuration:0.3
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         [self.renameOverlay setAlpha:0.0];
                     }
                     completion:^(BOOL finished) {
                         [self.renameOverlay removeFromSuperview];
                         self.renameOverlay = nil;
                     }];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    [self.renameTextField resignFirstResponder];
}
#endif

- (void)renameGame:(PVGame *)game toTitle:(NSString *)title;
{
    if (title.length)
    {
        [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
            [game setTitle:title];
        }];

        [self fetchGames];
        [self.collectionView reloadData];
    }
}

- (void)deleteGame:(PVGame *)game
{
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

    NSString *romPath = [[config documentsPath] stringByAppendingPathComponent:[game romPath]];
    NSArray *indexPaths = [self indexPathsForGameWithMD5Hash:[game md5Hash]];
    
    [PVMediaCache deleteImageForKey:[game originalArtworkURL]];
    [PVMediaCache deleteImageForKey:[game customArtworkURL]];
    
    NSError *error = nil;
    
    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:[config saveStatePathForROM:romPath] error:&error];
    if (!success)
    {
        DLog(@"Unable to delete save states at path: %@ because: %@", [config saveStatePathForROM:romPath], [error localizedDescription]);
    }
    
    success = [[NSFileManager defaultManager] removeItemAtPath:[config batterySavesPathForROM:romPath] error:&error];
    if (!success)
    {
        DLog(@"Unable to delete battery saves at path: %@ because: %@", [config batterySavesPathForROM:romPath], [error localizedDescription]);
    }
    
    success = [[NSFileManager defaultManager] removeItemAtPath:romPath error:&error];
    if (!success)
    {
        DLog(@"Unable to delete rom at path: %@ because: %@", romPath, [error localizedDescription]);
    }
    
    [self deleteRelatedFilesGame:game];
  
    [RomDatabase.sharedInstance deleteWithObject:game error:nil];
    
    NSArray *oldSectionInfo = self.sectionInfo;
    NSDictionary *oldGamesInSections = self.gamesInSections;
    [self fetchGames];
    
    [self.collectionView performBatchUpdates:^{
        [self.collectionView deleteItemsAtIndexPaths:indexPaths];
        
        for (NSIndexPath *indexPath in indexPaths)
        {
            NSString *sectionID = [oldSectionInfo objectAtIndex:[indexPath section]];
            NSUInteger count = [oldGamesInSections[sectionID] count];
            if (count == 1)
            {
                [self.collectionView deleteSections:[NSIndexSet indexSetWithIndex:[indexPath section]]];
            }
        }
    } completion:^(BOOL finished) {
    }];
}

- (void)deleteRelatedFilesGame:(PVGame *)game
{
    PVEmulatorConfiguration* config = [PVEmulatorConfiguration sharedInstance];

    NSString *romPath = [game romPath];
    NSString *romDirectory = [[config documentsPath] stringByAppendingPathComponent:[game systemIdentifier]];
    NSString *relatedFileName = [[romPath lastPathComponent] stringByReplacingOccurrencesOfString:[romPath pathExtension] withString:@""];
    NSError *error = nil;
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:romDirectory error:&error];
    
    if (!contents)
    {
        DLog(@"Error scanning %@, %@", romDirectory, [error localizedDescription]);
        return;
    }
    
    for (NSString *file in contents)
    {
        NSString *fileWithoutExtension = [file stringByReplacingOccurrencesOfString:[file pathExtension] withString:@""];
        
        if ([fileWithoutExtension isEqual:relatedFileName])
        {
            if (![[NSFileManager defaultManager] removeItemAtPath:[romDirectory stringByAppendingPathComponent:file]
                                                            error:&error])
            {
                DLog(@"Unable to delete file at %@ because %@", file, [error localizedDescription]);
            }
        }
    }
}

#if !TARGET_OS_TV
- (void)chooseCustomArtworkForGame:(PVGame *)game
{
    __weak PVGameLibraryViewController *weakSelf = self;
    
    UIActionSheet *imagePickerActionSheet = [[UIActionSheet alloc] init];
    
    BOOL cameraIsAvailable = [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera];
    BOOL photoLibraryIsAvaialble = [UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary];
    
    PVUIActionSheetAction cameraAction = ^{
        weakSelf.gameForCustomArt = game;
        UIImagePickerController *pickerController = [[UIImagePickerController alloc] init];
        [pickerController setDelegate:weakSelf];
        [pickerController setAllowsEditing:NO];
        [pickerController setSourceType:UIImagePickerControllerSourceTypeCamera];
        [weakSelf presentViewController:pickerController animated:YES completion:NULL];
    };
    
    PVUIActionSheetAction libraryAction = ^{
        weakSelf.gameForCustomArt = game;
        UIImagePickerController *pickerController = [[UIImagePickerController alloc] init];
        [pickerController setDelegate:weakSelf];
        [pickerController setAllowsEditing:NO];
        [pickerController setSourceType:UIImagePickerControllerSourceTypePhotoLibrary];
        [weakSelf presentViewController:pickerController animated:YES completion:NULL];
    };
    
    self.assetsLibrary = [[ALAssetsLibrary alloc] init];
    [self.assetsLibrary enumerateGroupsWithTypes:ALAssetsGroupSavedPhotos
                                      usingBlock:^(ALAssetsGroup *group, BOOL *stop) {
                                          if (!group)
                                          {
                                              return;
                                          }
                                          [group setAssetsFilter:[ALAssetsFilter allPhotos]];
                                          NSInteger index = [group numberOfAssets] - 1;
                                          DLog(@"Group: %@", group);
                                          if (index >= 0)
                                          {
                                              [group enumerateAssetsAtIndexes:[NSIndexSet indexSetWithIndex:index]
                                                                      options:0
                                                                   usingBlock:^(ALAsset *result, NSUInteger index, BOOL *stop) {
                                                                       ALAssetRepresentation *rep = [result defaultRepresentation];
                                                                       if (rep)
                                                                       {
                                                                           [imagePickerActionSheet PV_addButtonWithTitle:@"Use Last Photo Taken" action:^{
                                                                               UIImage *lastPhoto = [UIImage imageWithCGImage:[rep fullScreenImage]
                                                                                                                        scale:[rep scale]
                                                                                                                  orientation:(UIImageOrientation)[rep orientation]];
                                                                               [PVMediaCache writeImageToDisk:lastPhoto
                                                                                                      withKey:[[rep url] absoluteString]];
                                                                               [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
                                                                                   [game setCustomArtworkURL:[[rep url] absoluteString]];
                                                                               }];

                                                                               NSArray *indexPaths = [self indexPathsForGameWithMD5Hash:[game md5Hash]];
                                                                               [self fetchGames];
                                                                               [self.collectionView reloadItemsAtIndexPaths:indexPaths];
                                                                               weakSelf.assetsLibrary = nil;
                                                                           }];
                                                                           
                                                                           if (cameraIsAvailable || photoLibraryIsAvaialble)
                                                                           {
                                                                               if (cameraIsAvailable)
                                                                               {
                                                                                   [imagePickerActionSheet	PV_addButtonWithTitle:@"Take Photo..." action:cameraAction];
                                                                               }
                                                                               
                                                                               if (photoLibraryIsAvaialble)
                                                                               {
                                                                                   [imagePickerActionSheet PV_addButtonWithTitle:@"Choose from Library..." action:libraryAction];
                                                                               }
                                                                           }
                                                                           
                                                                           [imagePickerActionSheet PV_addCancelButtonWithTitle:@"Cancel" action:NULL];
                                                                           [imagePickerActionSheet showInView:self.view];
                                                                       }
                                                                   }];
                                          }
                                          else
                                          {
                                              UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Photos"
                                                                                                             message:@"There are no photos in your library to choose from"
                                                                                                      preferredStyle:UIAlertControllerStyleAlert];
                                              [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                                              [self presentViewController:alert animated:YES completion:nil];
                                          }
                                      } failureBlock:^(NSError *error) {
                                          if (cameraIsAvailable || photoLibraryIsAvaialble)
                                          {
                                              if (cameraIsAvailable)
                                              {
                                                  [imagePickerActionSheet	PV_addButtonWithTitle:@"Take Photo..." action:cameraAction];
                                              }
                                              
                                              if (photoLibraryIsAvaialble)
                                              {
                                                  [imagePickerActionSheet PV_addButtonWithTitle:@"Choose from Library..." action:libraryAction];
                                              }
                                          }
                                          [imagePickerActionSheet PV_addCancelButtonWithTitle:@"Cancel" action:NULL];
                                          [imagePickerActionSheet showInView:self.view];
                                          weakSelf.assetsLibrary = nil;
                                      }];
}

- (void)pasteCustomArtworkForGame:(PVGame *)game
{
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    UIImage *pastedImage = [pb image];
    NSURL *pastedURL = [pb URL];
    if (pastedURL != nil && pastedImage == nil) {
        pastedImage = [UIImage imageWithData: [NSData dataWithContentsOfURL:pastedURL]];
    }
    
    if (pastedImage != nil) {
        NSString *key;
        if (pastedURL != nil) {
            key = pastedURL.lastPathComponent;
        } else {
            key = [NSUUID UUID].UUIDString;
        }
        [PVMediaCache writeImageToDisk:pastedImage
                               withKey:key];
        
        [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
            [game setCustomArtworkURL:key];
        }];

        NSArray *indexPaths = [self indexPathsForGameWithMD5Hash:[game md5Hash]];
        [self fetchGames];
        [self.collectionView reloadItemsAtIndexPaths:indexPaths];
    }
}
#endif

- (NSString *)nameForSectionAtIndex:(NSInteger)section;
{
    NSString *systemID = [self.sectionInfo objectAtIndex:section];
    if ([systemID isEqualToString:@"recent"]) {
        return @"Recently Played";
    } else if ([systemID isEqualToString:@"favorite"]) {
        return @"Favorites";
    } else {
        return [[PVEmulatorConfiguration sharedInstance] shortNameForSystemIdentifier:systemID];
    }
}

#pragma mark - Searching

- (void)searchLibrary:(NSString *)searchText
{
    self.searchResults = [[PVGame objectsWhere:@"title CONTAINS[c] %@", searchText] sortedResultsUsingProperty:@"title" ascending:YES];
    [self.collectionView reloadData];
}

- (void)clearSearch
{
    [self.searchField setText:nil];
    self.searchResults = nil;
    [self.collectionView reloadData];
}

#pragma mark - UISearchResultsUpdating
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self searchLibrary:searchController.searchBar.text];
}


#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    NSInteger sections = 0;
    
    if (self.searchResults)
    {
        sections = 1;
    }
    else
    {
        sections = [self.sectionInfo count];
    }
    
    return sections;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    NSInteger items = 0;
    
    if (self.searchResults)
    {
        items = [self.searchResults count];
    }
    else
    {
        NSArray *games = [self.gamesInSections objectForKey:[self.sectionInfo objectAtIndex:section]];
        items = [games count];
    }
    
    return items;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
	PVGameLibraryCollectionViewCell *cell = [self.collectionView dequeueReusableCellWithReuseIdentifier:_reuseIdentifier forIndexPath:indexPath];
	
    PVGame *game = nil;
    
    if (self.searchResults)
    {
        game = [self.searchResults objectAtIndex:[indexPath item]];
    }
    else
    {
        NSArray *games = [self.gamesInSections objectForKey:[self.sectionInfo objectAtIndex:indexPath.section]];
        game = games[[indexPath item]];
    }
	
    [cell setupWithGame:game];
    
	return cell;
}

#pragma mark - UICollectionViewDelegate & UICollectionViewDelegateFlowLayout

#if TARGET_OS_TV
- (BOOL)collectionView:(UICollectionView *)collectionView canFocusItemAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldUpdateFocusInContext:(UICollectionViewFocusUpdateContext *)context
{
    return YES;
}
#endif

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
#if TARGET_OS_TV
    PVGame *game = [self gameAtIndexPath:indexPath];
    CGSize boxartSize = CGSizeMake(CellWidth, CellWidth / game.boxartAspectRatio);
    return [PVGameLibraryCollectionViewCell cellSizeForImageSize:boxartSize];
#else
    if ([[PVSettingsModel sharedInstance] showGameTitles]) {
        return CGSizeMake(100, 144);
    }
    return CGSizeMake(100, 100);
#endif
}

#if TARGET_OS_TV
- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section
{
    return 88;
}
#endif

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section
{
#if TARGET_OS_TV
    return 50;
#else
	return 5.0;
#endif
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout insetForSectionAtIndex:(NSInteger)section
{
#if TARGET_OS_TV
    	return UIEdgeInsetsMake(40, 0, 120, 0);
#else
    	return UIEdgeInsetsMake(5, 5, 5, 5);
#endif
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    PVGame *game = [self gameAtIndexPath:indexPath];
    [self loadGame:game];
}

- (PVGame *)gameAtIndexPath:(NSIndexPath *)indexPath
{
    PVGame *game = nil;
    if (self.searchResults)
    {
        game = [self.searchResults objectAtIndex:[indexPath item]];
    }
    else
    {
        NSArray *games = [self.gamesInSections objectForKey:[self.sectionInfo objectAtIndex:indexPath.section]];
        game = games[[indexPath item]];
    }
    
    return game;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath
{
    if ([kind isEqualToString:UICollectionElementKindSectionHeader])
	{
        PVGameLibrarySectionHeaderView *headerView = nil;
        
        if (self.searchResults)
        {
            headerView = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind
                                                                 withReuseIdentifier:PVGameLibraryHeaderView
                                                                        forIndexPath:indexPath];
            [[headerView titleLabel] setText:@"Search Results"];
        }
        else
        {
            headerView = [self.collectionView dequeueReusableSupplementaryViewOfKind:kind
                                                                 withReuseIdentifier:PVGameLibraryHeaderView
                                                                        forIndexPath:indexPath];
            NSString *title = [self nameForSectionAtIndex:[indexPath section]];
            [[headerView titleLabel] setText:title];
        }
		return headerView;
	}
	
	return nil;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section
{
#if TARGET_OS_TV
    return CGSizeMake([self.view bounds].size.width, 90);
#else
	return CGSizeMake([self.view bounds].size.width, 40);
#endif
}

#pragma mark - Text Field and Keyboard Delegate

#if !TARGET_OS_TV
- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (textField != self.searchField)
    {
        [self doneRenaming:self];
    }
    else
    {
        [textField resignFirstResponder];
    }
    
	return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField
{
    if (textField == self.searchField)
    {
        [textField performSelector:@selector(resignFirstResponder)
                        withObject:nil
                        afterDelay:0.0];
    }
    
    return YES;
}
#endif

- (void)handleTextFieldDidChange:(NSNotification *)notification
{
    if ([[self.searchField text] length])
    {
        [self searchLibrary:[self.searchField text]];
    }
    else
    {
        [self clearSearch];
    }
}

#if !TARGET_OS_TV
- (void)keyboardWillShow:(NSNotification *)note
{
	NSDictionary *userInfo = [note userInfo];
	
	CGRect keyboardEndFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
	keyboardEndFrame = [self.view.window convertRect:keyboardEndFrame toView:self.navigationController.view];
	CGFloat animationDuration = [[userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
	NSUInteger animationCurve = [[userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
	
	[UIView animateWithDuration:animationDuration
						  delay:0.0
						options:UIViewAnimationOptionBeginFromCurrentState | animationCurve
					 animations:^{
						 [self.renameToolbar setOriginY:keyboardEndFrame.origin.y - self.renameToolbar.frame.size.height];
					 }
					 completion:^(BOOL finished) {
					 }];
}
#endif

#if !TARGET_OS_TV
- (void)keyboardWillHide:(NSNotification *)note
{
	NSDictionary *userInfo = [note userInfo];
	
	CGFloat animationDuration = [[userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
	NSUInteger animationCurve = [[userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue];
	
	[UIView animateWithDuration:animationDuration
						  delay:0.0
						options:UIViewAnimationOptionBeginFromCurrentState | animationCurve
					 animations:^{
						 [self.renameToolbar setOriginY:[[UIScreen mainScreen] bounds].size.height];
					 }
					 completion:^(BOOL finished) {
						 [self.renameToolbar removeFromSuperview];
						 self.renameToolbar = nil;
						 self.renameTextField = nil;
					 }];
	
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIKeyboardWillShowNotification
												  object:nil];
	[[NSNotificationCenter defaultCenter] removeObserver:self
													name:UIKeyboardWillHideNotification
												  object:nil];
}
#endif

#pragma mark - Image Picker Delegate

#if !TARGET_OS_TV
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info
{
	[self dismissViewControllerAnimated:YES completion:NULL];
	
	UIImage *image = info[UIImagePickerControllerOriginalImage];
	image = [image scaledImageWithMaxResolution:PVThumbnailMaxResolution];
	
	if (image)
	{
        NSData *imageData = UIImagePNGRepresentation(image);
		NSString *hash = [imageData md5Hash];
		[PVMediaCache writeDataToDisk:imageData withKey:hash];
        
        [RomDatabase.sharedInstance writeTransactionAndReturnError:nil :^{
            [self.gameForCustomArt setCustomArtworkURL:hash];
        }];

        NSArray *indexPaths = [self indexPathsForGameWithMD5Hash:[self.gameForCustomArt md5Hash]];
		[self.collectionView reloadItemsAtIndexPaths:indexPaths];
	}
	
	self.gameForCustomArt = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
	[self dismissViewControllerAnimated:YES completion:NULL];
	self.gameForCustomArt = nil;
}
#endif

#pragma mark - Keyboard actions

- (NSArray<UIKeyCommand *>*)keyCommands {
    NSMutableArray<UIKeyCommand*> *sectionCommands = [NSMutableArray arrayWithCapacity:self.sectionInfo.count+2];
    
    for (int i=0; i<self.sectionInfo.count; i++) {
        NSString *input = [NSString stringWithFormat:@"%i", i];
        NSString *title = [self nameForSectionAtIndex:i];
        
        // Simulator Command + number has shorcuts already
#if TARGET_OS_SIMULATOR
        UIKeyModifierFlags flags = UIKeyModifierControl | UIKeyModifierCommand;
#else
        UIKeyModifierFlags flags = UIKeyModifierCommand;
#endif
        
        UIKeyCommand* command = [UIKeyCommand keyCommandWithInput:input modifierFlags:flags action:@selector(selectSection:) discoverabilityTitle:title];
        [sectionCommands addObject:command];
    }

    UIKeyCommand *findCommand =
    [UIKeyCommand keyCommandWithInput:@"f"
                        modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate
                               action:@selector(selectSearch:)
                 discoverabilityTitle:@"Find…"];
    [sectionCommands addObject:findCommand];
    
    return sectionCommands;
}

- (void)selectSearch:(UIKeyCommand *)sender {
    [self.searchField becomeFirstResponder];
}

- (void)selectSection:(UIKeyCommand *)sender {
    NSInteger section = [sender.input integerValue];
   
    [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:section] atScrollPosition:UICollectionViewScrollPositionTop animated:YES];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

@end
