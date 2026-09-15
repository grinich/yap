#import "WHZoomChatSupport.h"

NSDictionary *WHZoomChatRecipient(ZoomSDKChatInfo *message, unsigned int selfID, BOOL replying) {
    ZoomSDKChatMessageType type = [message getChatMessageType];
    if ([message isChatToWaitingRoom] || type == ZoomSDKChatMessageType_To_WaitingRoomUsers)
        return @{@"kind":@"waitingRoom", @"name":@"Waiting Room"};
    if (type == ZoomSDKChatMessageType_To_All_Panelist)
        return @{@"kind":@"panelists", @"name":@"All Panelists"};
    if (type == ZoomSDKChatMessageType_To_Individual_Panelist) {
        return @{@"kind":@"attendeeAndPanelists", @"participantID":@([message getReceiverUserID]).stringValue,
            @"name":[NSString stringWithFormat:@"%@ + all panelists", [message getReceiverDisplayName] ?: @"Attendee"]};
    }
    if (type == ZoomSDKChatMessageType_To_Individual) {
        BOOL toSender = replying && [message getSenderUserID] != selfID;
        unsigned int userID = toSender ? [message getSenderUserID] : [message getReceiverUserID];
        NSString *name = toSender ? [message getSenderDisplayName] : [message getReceiverDisplayName];
        return @{@"kind":@"participant", @"participantID":@(userID).stringValue, @"name":name ?: @"Participant"};
    }
    // Unknown types never become an Everyone reply.
    if (type != ZoomSDKChatMessageType_To_All) return @{@"kind":@"unavailable", @"name":@"Unknown audience"};
    return @{@"kind":@"everyone", @"name":@"Everyone"};
}

NSArray<NSDictionary *> *WHZoomChatRuns(ZoomSDKChatInfo *message) {
    NSMutableArray *runs = [NSMutableArray array];
    NSMutableString *text = [NSMutableString string];
    for (ZoomSDKChatMsgSegmentDetails *segment in [message getSegmentDetails] ?: @[]) {
        NSString *content = segment.strContent ?: @"";
        NSMutableDictionary *run = [@{@"text":content, @"bold":[NSNumber numberWithBool:segment.boldAttrs.bBold],
            @"italic":[NSNumber numberWithBool:segment.italicAttrs.bItalic], @"underline":[NSNumber numberWithBool:segment.underlineAttrs.bUnderline],
            @"strikethrough":[NSNumber numberWithBool:segment.strikethroughAttrs.bStrikethrough]} mutableCopy];
        NSString *link = segment.insertLinkAttrs.insertLinkUrl;
        if (link.length) run[@"link"] = link;
        [runs addObject:run]; [text appendString:content];
    }
    return [text isEqualToString:[message getMsgContent]] ? runs : @[];
}

ZoomSDKChatInfo *WHZoomBuildChatMessage(NSDictionary *draft, ZoomSDKMeetingChatController *chat, unsigned int selfID) {
    NSString *text = [draft[@"text"] isKindOfClass:NSString.class] ? draft[@"text"] : nil;
    NSDictionary *recipient = [draft[@"recipient"] isKindOfClass:NSDictionary.class] ? draft[@"recipient"] : nil;
    NSString *kind = recipient[@"kind"];
    if (!text.length || !recipient) return nil;
    unsigned int receiverID = 0;
    ZoomSDKChatMessageType type;
    if ([kind isEqual:@"everyone"]) type = ZoomSDKChatMessageType_To_All;
    else if ([kind isEqual:@"waitingRoom"]) type = ZoomSDKChatMessageType_To_WaitingRoomUsers;
    else if ([kind isEqual:@"panelists"]) type = ZoomSDKChatMessageType_To_All_Panelist;
    else if ([kind isEqual:@"participant"]) {
        NSString *identifier = recipient[@"participantID"];
        if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
            [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound ||
            identifier.longLongValue <= 0 || identifier.longLongValue > UINT32_MAX) return nil;
        receiverID = (unsigned int)identifier.longLongValue;
        type = ZoomSDKChatMessageType_To_Individual;
    } else return nil;
    ZoomSDKChatMsgInfoBuilder *builder = [[[ZoomSDKChatMsgInfoBuilder new] setContent:text] setReceiver:receiverID];
    builder = [builder setMessageType:type];
    NSString *replyID = [draft[@"replyToSDKID"] isKindOfClass:NSString.class] ? draft[@"replyToSDKID"] : nil;
    if (replyID.length) {
        ZoomSDKChatInfo *original = [chat getChatMessageById:replyID];
        if (!original || (![original isThread] && ![original isComment])) return nil;
        NSDictionary *expected = WHZoomChatRecipient(original, selfID, YES);
        if (![expected[@"kind"] isEqual:kind] || ![(expected[@"participantID"] ?: @"") isEqual:(recipient[@"participantID"] ?: @"")]) return nil;
        NSString *thread = [original getThreadID];
        if (!thread.length) thread = [original getMessageID];
        if (!thread.length) return nil;
        builder = [builder setThreadId:thread];
    }
    NSArray *runs = [draft[@"runs"] isKindOfClass:NSArray.class] ? draft[@"runs"] : @[];
    builder = WHZoomApplyChatStyles(builder, runs, text);
    return [builder build];
}

ZoomSDKChatMsgInfoBuilder *WHZoomApplyChatStyles(ZoomSDKChatMsgInfoBuilder *builder, NSArray *runs, NSString *text) {
    NSMutableString *combined = [NSMutableString string];
    for (NSDictionary *run in runs) {
        if (![run isKindOfClass:NSDictionary.class] || ![run[@"text"] isKindOfClass:NSString.class]) return nil;
        [combined appendString:run[@"text"]];
    }
    if (runs.count && ![combined isEqualToString:text]) return nil;
    NSUInteger offset = 0;
    for (NSDictionary *run in runs) {
        NSUInteger end = offset + [run[@"text"] length];
        if (end > offset) {
            if ([run[@"bold"] boolValue]) builder = [builder setBold:(unsigned int)offset positionEnd:(unsigned int)end];
            if ([run[@"italic"] boolValue]) builder = [builder setItalic:(unsigned int)offset positionEnd:(unsigned int)end];
            if ([run[@"underline"] boolValue]) builder = [builder setUnderline:(unsigned int)offset positionEnd:(unsigned int)end];
            if ([run[@"strikethrough"] boolValue]) builder = [builder setStrikethrough:(unsigned int)offset positionEnd:(unsigned int)end];
            NSString *link = run[@"link"];
            if ([link isKindOfClass:NSString.class] && link.length) {
                NSURL *url = [NSURL URLWithString:link];
                if (![@[@"https", @"http", @"mailto"] containsObject:url.scheme.lowercaseString]) return nil;
                ZoomSDKChatMsgInsertLinkAttrs *attrs = [ZoomSDKChatMsgInsertLinkAttrs new]; attrs.insertLinkUrl = link;
                builder = [builder setInsertLink:attrs positionStart:(unsigned int)offset positionEnd:(unsigned int)end];
            }
        }
        offset = end;
    }
    return builder;
}
