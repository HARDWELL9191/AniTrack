// Jellyfin API shapes (PascalCase, as the server sends them). Only the fields the app reads;
// checked against the Jellyfin 12.4 server source (Jellyfin.Api / MediaBrowser.Model).

export type Ticks = number; // 1 tick = 100 ns; 10,000,000 per second
export const TICKS_PER_SECOND = 10_000_000;
export const ticksToSeconds = (t?: number | null) => (t ?? 0) / TICKS_PER_SECOND;
export const secondsToTicks = (s: number) => Math.round(s * TICKS_PER_SECOND);

export type ItemKind =
  | "AggregateFolder" | "Audio" | "AudioBook" | "BasePluginFolder" | "Book" | "BoxSet" | "Channel" | "ChannelFolderItem"
  | "CollectionFolder" | "Episode" | "Folder" | "Genre" | "ManualPlaylistsFolder" | "Movie" | "LiveTvChannel" | "LiveTvProgram"
  | "MusicAlbum" | "MusicArtist" | "MusicGenre" | "MusicVideo" | "Person" | "Photo" | "PhotoAlbum" | "Playlist" | "PlaylistsFolder"
  | "Program" | "Recording" | "Season" | "Series" | "Studio" | "Trailer" | "TvChannel" | "TvProgram" | "UserRootFolder" | "UserView"
  | "Video" | "Year";

export type ImageType = "Primary" | "Art" | "Backdrop" | "Banner" | "Logo" | "Thumb" | "Disc" | "Box" | "Screenshot" | "Menu" | "Chapter" | "BoxRear" | "Profile";

export interface UserData {
  Rating?: number | null;
  PlayedPercentage?: number | null;
  UnplayedItemCount?: number | null;
  PlaybackPositionTicks?: number;
  PlayCount?: number;
  IsFavorite?: boolean;
  Likes?: boolean | null;
  LastPlayedDate?: string | null;
  Played?: boolean;
  Key?: string;
  ItemId?: string;
}

export interface NameId { Name?: string | null; Id: string }

export interface Person {
  Name?: string | null;
  Id: string;
  Role?: string | null;
  Type?: string;
  PrimaryImageTag?: string | null;
}

export interface Chapter {
  StartPositionTicks: number;
  Name?: string | null;
  ImageTag?: string | null;
}

export interface TrickplayInfo {
  Width: number;
  Height: number;
  TileWidth: number;
  TileHeight: number;
  ThumbnailCount: number;
  Interval: number; // milliseconds between thumbnails
  Bandwidth: number;
}

export interface MediaStream {
  Codec?: string | null;
  CodecTag?: string | null;
  Language?: string | null;
  ColorRange?: string | null;
  ColorSpace?: string | null;
  ColorTransfer?: string | null;
  ColorPrimaries?: string | null;
  DvProfile?: number | null;
  DvLevel?: number | null;
  Title?: string | null;
  VideoRange?: string;
  VideoRangeType?: string;
  VideoDoViTitle?: string | null;
  AudioSpatialFormat?: string;
  DisplayTitle?: string | null;
  IsInterlaced?: boolean;
  ChannelLayout?: string | null;
  BitRate?: number | null;
  BitDepth?: number | null;
  RefFrames?: number | null;
  Channels?: number | null;
  SampleRate?: number | null;
  IsDefault?: boolean;
  IsForced?: boolean;
  IsHearingImpaired?: boolean;
  Height?: number | null;
  Width?: number | null;
  AverageFrameRate?: number | null;
  RealFrameRate?: number | null;
  Profile?: string | null;
  Type: "Audio" | "Video" | "Subtitle" | "EmbeddedImage" | "Data" | "Lyric";
  AspectRatio?: string | null;
  Index: number;
  IsExternal?: boolean;
  DeliveryMethod?: "Encode" | "Embed" | "External" | "Hls" | "VideoSideData" | null;
  DeliveryUrl?: string | null;
  IsExternalUrl?: boolean | null;
  IsTextSubtitleStream?: boolean;
  SupportsExternalStream?: boolean;
  Path?: string | null;
  PixelFormat?: string | null;
  Level?: number | null;
  IsAnamorphic?: boolean | null;
}

export interface MediaAttachment {
  Codec?: string | null;
  Index: number;
  FileName?: string | null;
  MimeType?: string | null;
  DeliveryUrl?: string | null;
}

export interface MediaSource {
  Protocol?: "File" | "Http" | "Rtmp" | "Rtsp" | "Udp" | "Rtp" | "Ftp";
  Id?: string | null;
  Path?: string | null;
  Type?: "Default" | "Grouping" | "Placeholder";
  Container?: string | null;
  Size?: number | null;
  Name?: string | null;
  IsRemote?: boolean;
  RunTimeTicks?: number | null;
  SupportsTranscoding?: boolean;
  SupportsDirectStream?: boolean;
  SupportsDirectPlay?: boolean;
  IsInfiniteStream?: boolean;
  RequiresOpening?: boolean;
  RequiresClosing?: boolean;
  LiveStreamId?: string | null;
  VideoType?: string | null;
  MediaStreams?: MediaStream[] | null;
  MediaAttachments?: MediaAttachment[] | null;
  Bitrate?: number | null;
  RequiredHttpHeaders?: Record<string, string> | null;
  TranscodingUrl?: string | null;
  TranscodingSubProtocol?: string;
  TranscodingContainer?: string | null;
  DefaultAudioStreamIndex?: number | null;
  DefaultSubtitleStreamIndex?: number | null;
  HasSegments?: boolean;
}

export interface Item {
  Name?: string | null;
  OriginalTitle?: string | null;
  ServerId?: string | null;
  Id: string;
  Etag?: string | null;
  PlaylistItemId?: string | null;
  DateCreated?: string | null;
  CanDelete?: boolean | null;
  CanDownload?: boolean | null;
  HasSubtitles?: boolean | null;
  Container?: string | null;
  SortName?: string | null;
  PremiereDate?: string | null;
  ExternalUrls?: { Name?: string | null; Url?: string | null }[] | null;
  MediaSources?: MediaSource[] | null;
  CriticRating?: number | null;
  ProductionLocations?: string[] | null;
  Path?: string | null;
  OfficialRating?: string | null;
  CustomRating?: string | null;
  ChannelId?: string | null;
  ChannelName?: string | null;
  Overview?: string | null;
  Taglines?: string[] | null;
  Genres?: string[] | null;
  CommunityRating?: number | null;
  CumulativeRunTimeTicks?: number | null;
  RunTimeTicks?: number | null;
  ProductionYear?: number | null;
  Number?: string | null;
  ChannelNumber?: string | null;
  IndexNumber?: number | null;
  IndexNumberEnd?: number | null;
  ParentIndexNumber?: number | null;
  RemoteTrailers?: { Url?: string | null; Name?: string | null }[] | null;
  ProviderIds?: Record<string, string | null> | null;
  IsHD?: boolean | null;
  IsFolder?: boolean | null;
  ParentId?: string | null;
  Type: ItemKind;
  People?: Person[] | null;
  Studios?: NameId[] | null;
  GenreItems?: NameId[] | null;
  ParentLogoItemId?: string | null;
  ParentBackdropItemId?: string | null;
  ParentBackdropImageTags?: string[] | null;
  LocalTrailerCount?: number | null;
  UserData?: UserData | null;
  RecursiveItemCount?: number | null;
  ChildCount?: number | null;
  SeriesName?: string | null;
  SeriesId?: string | null;
  SeasonId?: string | null;
  SpecialFeatureCount?: number | null;
  Status?: string | null;
  AirTime?: string | null;
  AirDays?: string[] | null;
  Tags?: string[] | null;
  PrimaryImageAspectRatio?: number | null;
  Artists?: string[] | null;
  ArtistItems?: NameId[] | null;
  Album?: string | null;
  CollectionType?: string | null;
  AlbumId?: string | null;
  AlbumPrimaryImageTag?: string | null;
  SeriesPrimaryImageTag?: string | null;
  AlbumArtist?: string | null;
  AlbumArtists?: NameId[] | null;
  SeasonName?: string | null;
  MediaStreams?: MediaStream[] | null;
  VideoType?: string | null;
  PartCount?: number | null;
  MediaSourceCount?: number | null;
  ImageTags?: Partial<Record<ImageType, string>> | null;
  BackdropImageTags?: string[] | null;
  ParentLogoImageTag?: string | null;
  ParentThumbItemId?: string | null;
  ParentThumbImageTag?: string | null;
  SeriesThumbImageTag?: string | null;
  ImageBlurHashes?: Record<string, Record<string, string>> | null;
  Chapters?: Chapter[] | null;
  Trickplay?: Record<string, Record<string, TrickplayInfo>> | null;
  LocationType?: "FileSystem" | "Remote" | "Virtual" | "Offline";
  MediaType?: "Unknown" | "Video" | "Audio" | "Photo" | "Book";
  EndDate?: string | null;
  LockedFields?: string[] | null;
  LockData?: boolean | null;
  MovieCount?: number | null;
  SeriesCount?: number | null;
  EpisodeCount?: number | null;
  SongCount?: number | null;
  AlbumCount?: number | null;
  Width?: number | null;
  Height?: number | null;
  StartDate?: string | null;
  IsMovie?: boolean | null;
  IsSeries?: boolean | null;
  IsLive?: boolean | null;
  IsNews?: boolean | null;
  IsKids?: boolean | null;
  IsSports?: boolean | null;
  TimerId?: string | null;
  SeriesTimerId?: string | null;
  CurrentProgram?: Item | null;
  NormalizationGain?: number | null;
  EpisodeTitle?: string | null;
  CameraMake?: string | null;
  CameraModel?: string | null;
}

export interface ItemsResult {
  Items: Item[];
  TotalRecordCount: number;
  StartIndex?: number;
}

export interface UserPolicy {
  IsAdministrator: boolean;
  IsHidden: boolean;
  EnableCollectionManagement: boolean;
  EnableSubtitleManagement: boolean;
  EnableLyricManagement: boolean;
  IsDisabled: boolean;
  MaxParentalRating?: number | null;
  BlockedTags?: string[] | null;
  AllowedTags?: string[] | null;
  EnableUserPreferenceAccess: boolean;
  AccessSchedules?: unknown[] | null;
  BlockUnratedItems?: string[] | null;
  EnableRemoteControlOfOtherUsers: boolean;
  EnableSharedDeviceControl: boolean;
  EnableRemoteAccess: boolean;
  EnableLiveTvManagement: boolean;
  EnableLiveTvAccess: boolean;
  EnableMediaPlayback: boolean;
  EnableAudioPlaybackTranscoding: boolean;
  EnableVideoPlaybackTranscoding: boolean;
  EnablePlaybackRemuxing: boolean;
  ForceRemoteSourceTranscoding: boolean;
  EnableContentDeletion: boolean;
  EnableContentDeletionFromFolders?: string[] | null;
  EnableContentDownloading: boolean;
  EnableSyncTranscoding: boolean;
  EnableMediaConversion: boolean;
  EnabledDevices?: string[] | null;
  EnableAllDevices: boolean;
  EnabledChannels?: string[] | null;
  EnableAllChannels: boolean;
  EnabledFolders?: string[] | null;
  EnableAllFolders: boolean;
  InvalidLoginAttemptCount: number;
  LoginAttemptsBeforeLockout: number;
  MaxActiveSessions: number;
  EnablePublicSharing: boolean;
  BlockedMediaFolders?: string[] | null;
  BlockedChannels?: string[] | null;
  RemoteClientBitrateLimit: number;
  AuthenticationProviderId: string;
  PasswordResetProviderId: string;
  SyncPlayAccess: "CreateAndJoinGroups" | "JoinGroups" | "None";
  [key: string]: unknown;
}

export interface UserConfiguration {
  AudioLanguagePreference?: string | null;
  PlayDefaultAudioTrack: boolean;
  SubtitleLanguagePreference?: string | null;
  DisplayMissingEpisodes: boolean;
  GroupedFolders?: string[];
  SubtitleMode: "Default" | "Always" | "OnlyForced" | "None" | "Smart";
  DisplayCollectionsView: boolean;
  EnableLocalPassword: boolean;
  OrderedViews?: string[];
  LatestItemsExcludes?: string[];
  MyMediaExcludes?: string[];
  HidePlayedInLatest: boolean;
  RememberAudioSelections: boolean;
  RememberSubtitleSelections: boolean;
  EnableNextEpisodeAutoPlay: boolean;
  CastReceiverId?: string | null;
  [key: string]: unknown;
}

export interface User {
  Name?: string | null;
  ServerId?: string | null;
  Id: string;
  PrimaryImageTag?: string | null;
  HasPassword: boolean;
  HasConfiguredPassword: boolean;
  EnableAutoLogin?: boolean | null;
  LastLoginDate?: string | null;
  LastActivityDate?: string | null;
  Configuration?: UserConfiguration | null;
  Policy?: UserPolicy | null;
}

export interface AuthResult {
  User?: User | null;
  AccessToken?: string | null;
  ServerId?: string | null;
}

export interface PublicSystemInfo {
  LocalAddress?: string | null;
  ServerName?: string | null;
  Version?: string | null;
  ProductName?: string | null;
  Id?: string | null;
  StartupWizardCompleted?: boolean | null;
}

export interface SystemInfo extends PublicSystemInfo {
  OperatingSystemDisplayName?: string | null;
  HasPendingRestart: boolean;
  IsShuttingDown: boolean;
  SupportsLibraryMonitor: boolean;
  WebSocketPortNumber: number;
  CanSelfRestart: boolean;
  ProgramDataPath?: string | null;
  WebPath?: string | null;
  ItemsByNamePath?: string | null;
  CachePath?: string | null;
  LogPath?: string | null;
  InternalMetadataPath?: string | null;
  TranscodingTempPath?: string | null;
  HasUpdateAvailable?: boolean;
  EncoderLocation?: string;
  SystemArchitecture?: string;
}

export interface QuickConnectResult {
  Authenticated: boolean;
  Secret: string;
  Code: string;
  DeviceId: string;
  DeviceName: string;
  AppName: string;
  AppVersion: string;
}

export interface PlaybackInfoResponse {
  MediaSources: MediaSource[];
  PlaySessionId?: string | null;
  ErrorCode?: "NotAllowed" | "NoCompatibleStream" | "RateLimitExceeded" | null;
}

export type SegmentType = "Unknown" | "Commercial" | "Preview" | "Recap" | "Outro" | "Intro";
export interface MediaSegment {
  Id: string;
  ItemId: string;
  Type: SegmentType;
  StartTicks: number;
  EndTicks: number;
}

export interface SessionInfo {
  Id?: string | null;
  UserId: string;
  UserName?: string | null;
  Client?: string | null;
  LastActivityDate: string;
  DeviceName?: string | null;
  DeviceType?: string | null;
  DeviceId?: string | null;
  ApplicationVersion?: string | null;
  RemoteEndPoint?: string | null;
  IsActive: boolean;
  SupportsRemoteControl: boolean;
  SupportsMediaControl: boolean;
  NowPlayingItem?: Item | null;
  PlayState?: {
    PositionTicks?: number | null;
    CanSeek: boolean;
    IsPaused: boolean;
    IsMuted: boolean;
    VolumeLevel?: number | null;
    AudioStreamIndex?: number | null;
    SubtitleStreamIndex?: number | null;
    MediaSourceId?: string | null;
    PlayMethod?: "Transcode" | "DirectStream" | "DirectPlay" | null;
  } | null;
  TranscodingInfo?: {
    AudioCodec?: string | null;
    VideoCodec?: string | null;
    Container?: string | null;
    IsVideoDirect: boolean;
    IsAudioDirect: boolean;
    Bitrate?: number | null;
    Framerate?: number | null;
    CompletionPercentage?: number | null;
    Width?: number | null;
    Height?: number | null;
    AudioChannels?: number | null;
    HardwareAccelerationType?: string | null;
    TranscodeReasons?: string[];
  } | null;
  UserPrimaryImageTag?: string | null;
}

export interface VirtualFolder {
  Name?: string | null;
  Locations?: string[] | null;
  CollectionType?: string | null;
  LibraryOptions?: Record<string, unknown> | null;
  ItemId?: string | null;
  PrimaryImageItemId?: string | null;
  RefreshProgress?: number | null;
  RefreshStatus?: string | null;
}

export interface TaskInfo {
  Name?: string | null;
  State: "Idle" | "Cancelling" | "Running";
  CurrentProgressPercentage?: number | null;
  Id?: string | null;
  LastExecutionResult?: {
    StartTimeUtc: string;
    EndTimeUtc: string;
    Status: "Completed" | "Failed" | "Cancelled" | "Aborted";
    Name?: string | null;
    ErrorMessage?: string | null;
    LongErrorMessage?: string | null;
  } | null;
  Triggers?: TaskTrigger[] | null;
  Description?: string | null;
  Category?: string | null;
  IsHidden: boolean;
  Key?: string | null;
}

export interface TaskTrigger {
  Type: "DailyTrigger" | "WeeklyTrigger" | "IntervalTrigger" | "StartupTrigger";
  TimeOfDayTicks?: number | null;
  IntervalTicks?: number | null;
  DayOfWeek?: string | null;
  MaxRuntimeTicks?: number | null;
}

export interface ActivityLogEntry {
  Id: number;
  Name: string;
  Overview?: string | null;
  ShortOverview?: string | null;
  Type: string;
  ItemId?: string | null;
  Date: string;
  UserId: string;
  UserPrimaryImageTag?: string | null;
  Severity: "Trace" | "Debug" | "Information" | "Warning" | "Error" | "Critical" | "None";
}

export interface DeviceInfo {
  Name?: string | null;
  CustomName?: string | null;
  AccessToken?: string | null;
  Id?: string | null;
  LastUserName?: string | null;
  AppName?: string | null;
  AppVersion?: string | null;
  LastUserId?: string;
  DateLastActivity?: string;
  IconUrl?: string | null;
}

export interface PluginInfo {
  Name: string;
  Version: string;
  ConfigurationFileName?: string | null;
  Description: string;
  Id: string;
  CanUninstall: boolean;
  HasImage: boolean;
  Status: "Active" | "Restart" | "Deleted" | "Superseded" | "Malfunctioned" | "NotSupported" | "Disabled";
}

export interface PackageInfo {
  name: string;
  description: string;
  overview: string;
  owner: string;
  category: string;
  guid: string;
  versions: { version: string; VersionNumber?: string; changelog?: string | null; targetAbi?: string | null; sourceUrl?: string | null; timestamp?: string | null; repositoryName: string; repositoryUrl: string }[];
  imageUrl?: string | null;
}

export interface RepositoryInfo { Name?: string | null; Url?: string | null; Enabled: boolean }

export interface ApiKey {
  Id: number;
  AccessToken: string;
  DeviceId: string;
  AppName: string;
  AppVersion: string;
  DeviceName: string;
  UserId: string;
  IsActive: boolean;
  DateCreated: string;
  DateRevoked?: string | null;
  DateLastActivity: string;
  UserName?: string | null;
}

export interface LogFile { DateCreated: string; DateModified: string; Size: number; Name: string }

export interface BackupManifest {
  ServerVersion: string;
  BackupEngineVersion: string;
  DateCreated: string;
  Path: string;
  Options: BackupOptions;
}
export interface BackupOptions { Metadata: boolean; Trickplay: boolean; Subtitles: boolean; Database: boolean }

export interface RemoteImage {
  ProviderName?: string | null;
  Url?: string | null;
  ThumbnailUrl?: string | null;
  Height?: number | null;
  Width?: number | null;
  CommunityRating?: number | null;
  VoteCount?: number | null;
  Language?: string | null;
  Type: ImageType;
}

export interface RemoteSubtitle {
  ThreeLetterISOLanguageName?: string | null;
  Id?: string | null;
  ProviderName?: string | null;
  Name?: string | null;
  Format?: string | null;
  Author?: string | null;
  Comment?: string | null;
  DateCreated?: string | null;
  CommunityRating?: number | null;
  FrameRate?: number | null;
  DownloadCount?: number | null;
  IsHashMatch?: boolean | null;
  AiTranslated?: boolean | null;
  MachineTranslated?: boolean | null;
  Forced?: boolean | null;
  HearingImpaired?: boolean | null;
}

export interface RemoteSearchResult {
  Name?: string | null;
  ProviderIds?: Record<string, string> | null;
  ProductionYear?: number | null;
  ImageUrl?: string | null;
  SearchProviderName?: string | null;
  Overview?: string | null;
  PremiereDate?: string | null;
}

export interface Culture { DisplayName: string; Name: string; ThreeLetterISOLanguageName?: string | null; TwoLetterISOLanguageName?: string | null }
export interface Country { DisplayName: string; Name: string; TwoLetterISORegionName?: string | null }
export interface ParentalRating { Name: string; Value?: number | null }

export interface SyncPlayGroup { GroupId: string; GroupName: string; State: string; Participants: string[]; LastUpdatedAt: string }

export interface LyricLine { Text: string; Start?: number | null }
export interface Lyrics { Metadata?: Record<string, unknown>; Lyrics: LyricLine[] }

export interface FileSystemEntry { Name: string; Path: string; Type: "File" | "Directory" | "NetworkComputer" | "NetworkShare" }
