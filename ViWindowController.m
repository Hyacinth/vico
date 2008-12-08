#import "ViWindowController.h"
#import <PSMTabBarControl/PSMTabBarControl.h>
#import "ViDocument.h"
#import "ExTextView.h"
#import "ProjectDelegate.h"
#import "ViSymbol.h"
#import "ViSeparatorCell.h"
#import "ViSymbolSearchField.h"

static NSMutableArray		*windowControllers = nil;
static NSWindowController	*currentWindowController = nil;

@interface ViWindowController ()
- (ViDocumentView *)documentViewForView:(NSView *)aView;
- (void)collapseDocumentView:(ViDocumentView *)docView;
@end


#pragma mark -
@implementation ViWindowController

@synthesize documents;
@synthesize selectedDocument;
@synthesize statusbar;

+ (id)currentWindowController
{
	if (currentWindowController == nil)
		[[ViWindowController alloc] init];
	return currentWindowController;
}

+ (NSWindow *)currentMainWindow
{
	if (currentWindowController)
		return [currentWindowController window];
	else if ([windowControllers count] > 0)
		return [[windowControllers objectAtIndex:0] window];
	else
		return nil;
}

- (id)init
{
	self = [super initWithWindowNibName:@"ViDocumentWindow"];
	if (self)
	{
		[self setShouldCascadeWindows:NO];
		isLoaded = NO;
		if (windowControllers == nil)
			windowControllers = [[NSMutableArray alloc] init];
		[windowControllers addObject:self];
		currentWindowController = self;
		documents = [[NSMutableArray alloc] init];
		symbolFilterCache = [[NSMutableDictionary alloc] init];
	}

	return self;
}

- (IBAction)saveProject:(id)sender
{
	[projectDelegate saveProject:sender];
}

- (void)windowDidLoad
{
	[toolbar setDelegate:self];
	[[self window] setToolbar:toolbar];

	[[tabBar addTabButton] setTarget:self];
	[[tabBar addTabButton] setAction:@selector(addNewDocumentTab:)];
	[tabBar setStyleNamed:@"Unified"];
	[tabBar setCanCloseOnlyTab:YES];
	[tabBar setHideForSingleTab:NO];
	[tabBar setPartnerView:splitView];
	[tabBar setShowAddTabButton:YES];
	[tabBar setAllowsDragBetweenWindows:NO];

	[[self window] setDelegate:self];
	[[self window] setFrameUsingName:@"MainDocumentWindow"];

	[splitView addSubview:symbolsView];
	[splitView setAutosaveName:@"ProjectSymbolSplitView"];

	isLoaded = YES;
	if (initialDocument)
	{
		[self addNewTab:initialDocument];
                lastDocument = initialDocument;
                lastDocumentView = [[lastDocument views] objectAtIndex:0];
                initialDocument = nil;
	}

	NSCell *cell = [(NSTableColumn *)[[projectOutline tableColumns] objectAtIndex:0] dataCell];
	// [cell setFont:[NSFont systemFontOfSize:11.0]];
	// [projectOutline setRowHeight:15.0];
	[cell setLineBreakMode:NSLineBreakByTruncatingTail];
	[cell setWraps:NO];

	[[self window] makeKeyAndOrderFront:self];

	[symbolsOutline setTarget:self];
	[symbolsOutline setDoubleAction:@selector(goToSymbol:)];
	[symbolsOutline setAction:@selector(goToSymbol:)];
	cell = [(NSTableColumn *)[[symbolsOutline tableColumns] objectAtIndex:0] dataCell];
	[cell setLineBreakMode:NSLineBreakByTruncatingTail];
	[cell setWraps:NO];

	[statusbar setFont:[NSFont userFixedPitchFontOfSize:12.0]];

	separatorCell = [[ViSeparatorCell alloc] init];
}

- (id)windowWillReturnFieldEditor:(NSWindow *)window toObject:(id)anObject
{
	if ([anObject isKindOfClass:[NSTextField class]] && anObject != symbolFilterField)
	{
		return [ExTextView defaultEditor];
	}
	return nil;
}

- (IBAction)addNewDocumentTab:(id)sender
{
	[[NSDocumentController sharedDocumentController] newDocument:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ([keyPath isEqualToString:@"symbols"])
	{
		[self filterSymbols:symbolFilterField];
		if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autocollapse"] == YES)
		{
			[symbolsOutline collapseItem:nil collapseChildren:YES];
			[symbolsOutline expandItem:[self currentDocument]];
		}
	}
}

/* Called by a new ViDocument in its makeWindowControllers method.
 */
- (void)addNewTab:(ViDocument *)document
{
	if (!isLoaded)
	{
		/* Defer until NIB is loaded. */
		initialDocument = document;
		return;
	}

	[tabBar addDocument:document];
	[self selectDocument:document];

	// update symbol table
	[documents addObject:document];
	[self filterSymbols:symbolFilterField];
	[document addObserver:self forKeyPath:@"symbols" options:0 context:NULL];
        NSInteger row = [symbolsOutline rowForItem:document];
        [symbolsOutline scrollRowToVisible:row];
        [symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)setMostRecentDocument:(ViDocument *)document view:(ViDocumentView *)docView
{
	if (mostRecentView == docView)
		return;

	lastDocument = mostRecentDocument;
	lastDocumentView = mostRecentView;

	mostRecentDocument = document;
	mostRecentView = docView;

	[[self document] removeWindowController:self];
	[document addWindowController:self];
	[self setDocument:document];

	[self setSelectedDocument:document];
	[tabBar didSelectDocument:document];

	[[self window] makeFirstResponder:[docView textView]];
 
	// update symbol list
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"autocollapse"] == YES)
		[symbolsOutline collapseItem:nil collapseChildren:YES];
        [symbolsOutline expandItem:document];
        
        // unless current selection is a symbol in the current document, select the document itself
        id selectedItem = [symbolsOutline itemAtRow:[symbolsOutline selectedRow]];
        if (selectedItem != document && [symbolsOutline parentForItem:selectedItem] != document)
        {
		NSInteger row = [symbolsOutline rowForItem:document];
		[symbolsOutline scrollRowToVisible:row];
		[symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        }
}

- (void)selectDocument:(ViDocument *)aDocument
{
	if (!isLoaded || aDocument == nil)
		return;

	if (mostRecentDocument == aDocument)
		return;

	NSView *superView = [[mostRecentView view] superview];

	// create a new document view
	ViDocumentView *docView = [aDocument makeView];

	// add the new view
	if (mostRecentView == nil)
	{
		NSRect frame = [documentView frame];
		frame.origin = NSMakePoint(0, 0);
		NSSplitView *split = [[NSSplitView alloc] initWithFrame:frame];
		[split setVertical:NO];
		[split setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[split addSubview:[docView view]];
		[split adjustSubviews];
		[documentView addSubview:split];
	}
	else
	{
		[mostRecentDocument removeView:mostRecentView];
		[superView replaceSubview:[mostRecentView view] with:[docView view]];
		mostRecentView = nil;
	}

	[self setMostRecentDocument:aDocument view:docView];
}

#pragma mark -
#pragma mark Document closing

- (BOOL)windowShouldClose:(id)window
{
	INFO(@"have %u documents", [documents count]);
	return [documents count] == 0;
}

- (void)windowWillClose:(NSNotification *)aNotification
{
	if (currentWindowController == self)
		currentWindowController = nil;
	[windowControllers removeObject:self];
	[tabBar setDelegate:nil];
}

- (void)closeDocumentViews:(ViDocument *)document
{
	INFO(@"close document %@", document);
	[document removeObserver:self forKeyPath:@"symbols"];

	while ([document visibleViews] > 0)
		[self collapseDocumentView:[[document views] objectAtIndex:0]];

	[tabBar removeDocument:document];
	if (lastDocument == document)
	{
		lastDocument = nil;
		lastDocumentView = nil;
	}

	if ([documents count] == 0)
	{
		INFO(@"no documents left, closing window");
		[[self window] close];
	}
	else
	{
		/* Reset the most recent document and view.
		 */
		mostRecentView = nil;
		mostRecentDocument = nil;

		BOOL foundVisibleView = NO;
		if (lastDocument && lastDocument != document)
		{
			if ([lastDocument visibleViews] > 0)
			{
				[self setMostRecentDocument:lastDocument view:lastDocumentView];
				foundVisibleView = YES;
			}
			else
			{
				[self selectDocument:lastDocument];
				foundVisibleView = YES;
			}
		}
		
		if (!foundVisibleView)
		{
			for (document in documents)
			{
				if ([document visibleViews] > 0)
				{
					[self setMostRecentDocument:document view:[[document views] objectAtIndex:0]];
					foundVisibleView = YES;
					break;
				}
			}
		}
		
		if (!foundVisibleView)
		{
			// no visible view found, make one
			[self selectDocument:[documents objectAtIndex:0]];
		}

		[documents removeObject:document];
		[self filterSymbols:symbolFilterField];
	}
}

- (void)closeDocument:(ViDocument *)document
{
	if ([document visibleViews] > 0)
		[self setMostRecentDocument:document view:[[document views] objectAtIndex:0]];
	else
		[self selectDocument:document];
	[[self window] performClose:self];
}

- (void)windowDidResize:(NSNotification *)aNotification
{
	[[self window] saveFrameUsingName:@"MainDocumentWindow"];
}

#pragma mark -

- (void)windowDidBecomeMain:(NSNotification *)aNotification
{
	currentWindowController = self;
}

- (ViDocument *)currentDocument
{
	return mostRecentDocument;
}

- (IBAction)selectNextTab:(id)sender
{
	NSArray *tabs = [tabBar representedDocuments];
	int num = [tabs count];
	if (num <= 1)
		return;

	int i;
	for (i = 0; i < num; i++)
	{
		if ([tabs objectAtIndex:i] == [self selectedDocument])
		{
			if (++i >= num)
				i = 0;
			[self selectDocument:[tabs objectAtIndex:i]];
			break;
		}
	}
}

- (IBAction)selectPreviousTab:(id)sender
{
	NSArray *tabs = [tabBar representedDocuments];
	int num = [tabs count];
	if (num <= 1)
		return;

	int i;
	for (i = 0; i < num; i++)
	{
		if ([tabs objectAtIndex:i] == [self selectedDocument])
		{
			if (--i < 0)
				i = num - 1;
			[self selectDocument:[tabs objectAtIndex:i]];
			break;
		}
	}
}

- (ViTagStack *)sharedTagStack
{
	if (tagStack == nil)
		tagStack = [[ViTagStack alloc] init];
	return tagStack;
}

- (NSString *)windowTitleForDocumentDisplayName:(NSString *)displayName
{
	NSString *projName = [projectDelegate projectName];
	if (projName)
		return [NSString stringWithFormat:@"%@ - %@", displayName, projName];
	return displayName;
}

- (void)switchToLastFile
{
        if ([lastDocument visibleViews] > 0)
        {
		[self setMostRecentDocument:lastDocument view:lastDocumentView ?: [[lastDocument views] objectAtIndex:0]];
	}
        else
		[self selectDocument:lastDocument];
}

#pragma mark -
#pragma mark View Splitting

- (IBAction)splitViewHorizontally:(id)sender
{
	NSView *view = [mostRecentView view];
	NSSplitView *split = (NSSplitView *)[view superview];
	if (![split isKindOfClass:[NSSplitView class]])
	{
		INFO(@"***** superview not an NSSplitView!? %@", split);
		return;
	}

	ViDocumentView *dv = [mostRecentDocument makeView];

	if (![split isVertical])
	{
		// Just add another view to this split
		[split addSubview:[dv view]];
		[split adjustSubviews];
	}
	else
	{
		// Need to create a new horizontal split view and replace
		// the current view with the split and two subviews
		NSRect frame = [view frame];
		frame.origin = NSMakePoint(0, 0);
		NSSplitView *newSplit = [[NSSplitView alloc] initWithFrame:frame];
		[newSplit setVertical:NO];
		[newSplit setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
		[split replaceSubview:view with:newSplit];
		[newSplit addSubview:view];
		[newSplit addSubview:[dv view]];
		[newSplit adjustSubviews];
	}

	[self setMostRecentDocument:mostRecentDocument view:dv];
}

- (IBAction)splitViewVertically:(id)sender
{
	NSView *view = [mostRecentView view];
	NSSplitView *split = (NSSplitView *)[view superview];
	if (![split isKindOfClass:[NSSplitView class]])
	{
		INFO(@"***** superview not an NSSplitView!? %@", split);
		return;
	}

	ViDocumentView *dv = [mostRecentDocument makeView];
	int nsubviews = [[split subviews] count];
	if ([split isVertical])
	{
		// Just add another view to this split
		[split addSubview:[dv view]];
		[split adjustSubviews];
	}
	else
	{
		if (nsubviews == 1)
		{
			// There is only one view in this horizontal split.
			// Change it to a vertical split.
			[split setVertical:YES];
			[split addSubview:[dv view]];
			[split adjustSubviews];
		}
		else
		{
			// Need to create a new vertial split view and replace
			// the current view with the split and two subviews
			NSRect frame = [view frame];
			frame.origin = NSMakePoint(0, 0);
			NSSplitView *newSplit = [[NSSplitView alloc] initWithFrame:frame];
			[newSplit setVertical:YES];
			[newSplit setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
			[split replaceSubview:view with:newSplit];
			[newSplit addSubview:view];
			[newSplit addSubview:[dv view]];
			[newSplit adjustSubviews];
		}
	}

	[self setMostRecentDocument:mostRecentDocument view:dv];
}

- (ViDocumentView *)documentViewForView:(NSView *)aView
{
	ViDocument *doc;
	for (doc in documents) // XXX: should maybe ask the tab bar for the documents?
	{
		ViDocumentView *dv;
		for (dv in [doc views])
		{
			if ([dv view] == aView)
				return dv;
		}
	}
	INFO(@"***** View %@ not a document view!?", aView);
	return nil;
}

- (IBAction)collapseSplitView:(id)sender
{
	NSView *view = [mostRecentView view];
	NSSplitView *split = (NSSplitView *)[view superview];
	if (![split isKindOfClass:[NSSplitView class]])
	{
		INFO(@"***** superview not an NSSplitView!? %@", split);
		return;
	}

	if ([[split subviews] count] == 1)
	{
		// beep
		return;
	}
	
	// Find index of current subview.
	int cur;
	for (cur = 0; cur < [[split subviews] count]; cur++)
	{
		if ([[split subviews] objectAtIndex:cur] == view)
			break;
	}

	NSView *delView;
	if (cur == 0)
		delView = [[split subviews] objectAtIndex:1];
	else
		delView = [[split subviews] objectAtIndex:cur - 1];

	ViDocumentView *docView = [self documentViewForView:delView];
	[self collapseDocumentView:docView];
}

- (void)collapseDocumentView:(ViDocumentView *)docView
{
	[[docView document] removeView:docView];

	NSSplitView *split = (NSSplitView *)[[docView view] superview];

	[[docView view] removeFromSuperview];

	if (![split isKindOfClass:[NSSplitView class]])
	{
		INFO(@"***** superview not an NSSplitView!? %@", split);
		return;
	}

	if ([[split subviews] count] == 1)
	{
		NSSplitView *supersplit = (NSSplitView *)[split superview];
		if ([supersplit isKindOfClass:[NSSplitView class]])
		{
			NSView *view = [[split subviews] objectAtIndex:0];
			[view removeFromSuperview];
			[supersplit replaceSubview:split with:view];
			[supersplit adjustSubviews];
		}
	}
}

#pragma mark -
#pragma mark Split view delegate methods

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview
{
	if (sender == splitView)
		return YES;
	return NO;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)offset
{
	if (sender == splitView)
	{
		if (offset == 0)
			return 100;
		NSRect frame = [sender frame];
		return frame.size.width - 300;
	}
	else
		return proposedMin;
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)offset
{
	if (sender == splitView)
	{
		if (offset == 0)
			return 300;
		return proposedMax - 100;
	}
	else
		return proposedMax;
}

- (BOOL)splitView:(NSSplitView *)sender shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex
{
	if (sender == splitView)
	{
		// collapse both side views, but not the edit view
		NSView *secondView = [[sender subviews] objectAtIndex:1];
		if (subview == secondView)
			return NO;
		return YES;
	}
	else
		return NO;
}

- (void)splitView:(id)sender resizeSubviewsWithOldSize:(NSSize)oldSize
{
	if (sender != splitView)
		return;

	NSRect newFrame = [sender frame];
	float dividerThickness = [sender dividerThickness];
	
	NSView *firstView = [[sender subviews] objectAtIndex:0];
	NSView *secondView = [[sender subviews] objectAtIndex:1];
	NSView *thirdView = nil;
	int nsubviews = [[sender subviews] count];
	if (nsubviews == 3)
		thirdView = [[sender subviews] objectAtIndex:2];

	NSRect firstFrame = [firstView frame];
	NSRect secondFrame = [secondView frame];
	NSRect thirdFrame = [thirdView frame];

	NSInteger firstWidth = firstFrame.size.width;
	if ([splitView isSubviewCollapsed:firstView])
		firstWidth = 0;

	NSInteger thirdWidth = thirdFrame.size.width;
	if ([splitView isSubviewCollapsed:thirdView])
		thirdWidth = 0;

	/* keep sidebar in constant width */
	secondFrame.size.width = newFrame.size.width - (firstWidth + thirdWidth + dividerThickness);
	secondFrame.size.height = newFrame.size.height;

	[secondView setFrame:secondFrame];
	[sender adjustSubviews];
}

- (NSRect)splitView:(NSSplitView *)sender additionalEffectiveRectOfDividerAtIndex:(NSInteger)dividerIndex
{
	if (sender != splitView)
		return NSMakeRect(0, 0, 0, 0);

	NSRect frame = [sender frame];
	NSRect resizeRect;
	if (dividerIndex == 0)
	{
		resizeRect = [projectResizeView frame];
	}
	else if (dividerIndex == 1)
	{
		resizeRect = [symbolsResizeView frame];
		resizeRect.origin = [sender convertPoint:resizeRect.origin fromView:symbolsResizeView];
	}
	else
		return NSMakeRect(0, 0, 0, 0);

	resizeRect.origin.y = NSHeight(frame) - NSHeight(resizeRect);
	return resizeRect;
}

#pragma mark -
#pragma mark Symbol List

- (IBAction)toggleSymbolList:(id)sender
{
	NSRect frame = [splitView frame];
	if ([splitView isSubviewCollapsed:symbolsView])
		[splitView setPosition:NSWidth(frame) - 200 ofDividerAtIndex:1];
	else
		[splitView setPosition:NSWidth(frame) ofDividerAtIndex:1];
}

- (void)goToSymbol:(id)sender
{
	id item = [symbolsOutline itemAtRow:[symbolsOutline selectedRow]];
	if ([item isKindOfClass:[ViDocument class]])
	{
		[self selectDocument:item];
		[[self window] makeFirstResponder:[item textView]];
	}
	else
	{
		ViDocument *document = [symbolsOutline parentForItem:item];
		[self selectDocument:document];
		[document goToSymbol:item];

		// remember what symbol we selected from the filtered set
		NSString *filter = [symbolFilterField stringValue];
		[symbolFilterCache setObject:[item symbol] forKey:filter];
	}

	[symbolFilterField setStringValue:@""];
	[self filterSymbols:symbolFilterField];

        NSInteger row = [symbolsOutline rowForItem:item];
        [symbolsOutline scrollRowToVisible:row];
        [symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];

	if (closeSymbolListAfterUse)
	{
		[self toggleSymbolList:self];
		closeSymbolListAfterUse = NO;
	}
}

- (IBAction)searchSymbol:(id)sender
{
	if ([splitView isSubviewCollapsed:symbolsView])
	{
		closeSymbolListAfterUse = YES;
		[self toggleSymbolList:nil];
	}
	[[self window] makeFirstResponder:symbolFilterField];
}

- (void)selectFirstMatchingSymbolForFilter:(NSString *)filter
{
	NSUInteger row;

	NSString *symbol = [symbolFilterCache objectForKey:filter];
	if (symbol)
	{
		// check if the cached symbol is available, then select it
		for (row = 0; row < [symbolsOutline numberOfRows]; row++)
		{
			id item = [symbolsOutline itemAtRow:row];
			if ([item isKindOfClass:[ViSymbol class]] && [[item symbol] isEqualToString:symbol])
			{
				[symbolsOutline scrollRowToVisible:row];
				[symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
				return;
			}
		}
	}

	// skip past all document entries, selecting the first symbol
	for (row = 0; row < [symbolsOutline numberOfRows]; row++)
	{
		id item = [symbolsOutline itemAtRow:row];
		if ([item isKindOfClass:[ViSymbol class]])
		{
			[symbolsOutline scrollRowToVisible:row];
			[symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
			break;
		}
	}
}

- (IBAction)filterSymbols:(id)sender
{
	NSString *filter = [sender stringValue];

	NSMutableString *pattern = [NSMutableString string];
	int i;
	for (i = 0; i < [filter length]; i++)
	{
		[pattern appendFormat:@".*%C", [filter characterAtIndex:i]];
	}
	[pattern appendString:@".*"];

	ViRegexp *rx = [ViRegexp regularExpressionWithString:pattern options:ONIG_OPTION_IGNORECASE];

	filteredDocuments = [[NSMutableArray alloc] initWithArray:documents];

	// make sure the current document is displayed first in the symbol list
	ViDocument *currentDocument = [self currentDocument];
	if (currentDocument)
	{
		[filteredDocuments removeObject:currentDocument];
		[filteredDocuments insertObject:currentDocument atIndex:0];
	}

	ViDocument *doc;
	NSMutableArray *emptyDocuments = [[NSMutableArray alloc] init];
	for (doc in filteredDocuments)
	{
		if ([doc filterSymbols:rx] == 0)
			[emptyDocuments addObject:doc];
	}
	[filteredDocuments removeObjectsInArray:emptyDocuments];
	[symbolsOutline reloadData];
	[symbolsOutline expandItem:nil expandChildren:YES];
	[self selectFirstMatchingSymbolForFilter:filter];
}

- (BOOL)searchField:(NSSearchField *)aSearchField doCommandBySelector:(SEL)aSelector
{
	INFO(@"selector = %s", aSelector);

	if (aSelector == @selector(insertNewline:)) // enter
	{
		[self goToSymbol:self];
		return YES;
	}
	else if (aSelector == @selector(moveUp:)) // up arrow
	{
		NSInteger row = [symbolsOutline selectedRow];
		if (row > 0)
		{
			[symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1] byExtendingSelection:NO];
		}
		return YES;
	}
	else if (aSelector == @selector(moveDown:)) // down arrow
	{
		NSInteger row = [symbolsOutline selectedRow];
		if (row + 1 < [symbolsOutline numberOfRows])
		{
			[symbolsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
		}
		return YES;
	}
	else if (aSelector == @selector(cancelOperation:)) // escape
	{
		if (closeSymbolListAfterUse)
		{
			[self toggleSymbolList:self];
			closeSymbolListAfterUse = NO;
		}
		[symbolFilterField setStringValue:@""];
		[self filterSymbols:symbolFilterField];
		[[self window] makeFirstResponder:[mostRecentView view]];
		return YES;
	}

	return NO;
}

#pragma mark -
#pragma mark Symbol Outline View Data Source

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)anIndex ofItem:(id)item
{
	if (item == nil)
		return [filteredDocuments objectAtIndex:anIndex];
	return [[(ViDocument *)item filteredSymbols] objectAtIndex:anIndex];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	if ([item isKindOfClass:[ViDocument class]])
	{
		return [[(ViDocument *)item filteredSymbols] count] > 0 ? YES : NO;
	}
	return NO;
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	if (item == nil)
		return [filteredDocuments count];

	if ([item isKindOfClass:[ViDocument class]])
		return [[(ViDocument *)item filteredSymbols] count];

	return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	return [item displayName];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item
{
	if ([item isKindOfClass:[ViDocument class]])
		return YES;
	return NO;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item
{
	if ([item isKindOfClass:[ViDocument class]])
		return 20;
	return 15;
}


- (NSCell *)outlineView:(NSOutlineView *)outlineView dataCellForTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
	NSCell *cell;
	if ([item isKindOfClass:[ViSymbol class]] && [[(ViSymbol *)item symbol] isEqualToString:@"-"])
	{
		cell = separatorCell;
	}
	else
		cell  = [tableColumn dataCellForRow:[symbolsOutline rowForItem:item]];
	if (![item isKindOfClass:[ViDocument class]])
		[cell setFont:[NSFont systemFontOfSize:11.0]];
	else
		[cell setFont:[NSFont systemFontOfSize:13.0]];
	return cell;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item
{
	if ([item isKindOfClass:[ViSymbol class]] && [[(ViSymbol *)item symbol] isEqualToString:@"-"])
		return NO;
	return YES;
}

@end

