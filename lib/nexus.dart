/// Nexus — one Flutter SDK for all Inverge Nexus services.
///
/// Initialise once, then use any service (all correlated to one session):
///
/// ```dart
/// await Nexus.init(const NexusConfig(apiKey: 'nxs_...'));
/// runApp(NexusScope(child: MyApp()));
/// // …
/// context.nexus.events.track('signed_up');
/// context.nexus.realtime.join('orders:42');
/// ```
library;

export 'src/nexus.dart' show Nexus;
export 'src/config.dart' show NexusConfig, NexusDeepLinkHandler;
export 'src/logging.dart' show NexusLog, NexusLogLevel, NexusLogSink;
export 'src/context.dart' show NexusScope, NexusBuildContext;

export 'src/services/sessions_service.dart' show NexusSessions;
export 'src/services/events_service.dart' show NexusEvents;
export 'src/services/errors_service.dart' show NexusErrors;
export 'src/services/logs_service.dart' show NexusLogs;
export 'src/services/flags_service.dart' show NexusFlags;
export 'src/services/links_service.dart' show NexusLinks, NexusDeepLink, NexusDeepLinkSource;
export 'src/services/push_service.dart' show NexusPush, PushPlatform, PushProvider;
export 'src/services/realtime_service.dart'
    show NexusRealtime, NexusEventHandler;
export 'src/services/remote_config_service.dart' show NexusRemoteConfig;
export 'src/services/replay_service.dart' show NexusReplay;
export 'src/replay/replay_mask.dart' show NexusMask;
export 'src/replay/nexus_navigator_observer.dart' show NexusNavigatorObserver;

// Surveys: service, models, controller, and the customizable UI.
export 'src/services/surveys_service.dart' show NexusSurveys;
export 'src/surveys/survey_models.dart'
    show
        NexusSurvey,
        NexusSurveyQuestion,
        NexusSurveyChoice,
        NexusSurveyTrigger;
export 'src/surveys/survey_controller.dart'
    show NexusSurveyController, SurveySubmit;
export 'src/surveys/survey_view.dart'
    show NexusSurveyView, NexusQuestionBuilder;
export 'src/surveys/survey_overlay.dart'
    show NexusSurveyOverlay, NexusSurveyBuilder;

// In-app messages (OneSignal-style).
export 'src/services/inapp_service.dart' show NexusInApp;
// Live Activities (iOS ActivityKit + Android live notifications).
export 'src/services/live_activity_service.dart' show NexusLiveActivity;
export 'src/services/voice_service.dart' show NexusVoice;
// Shield — app & device integrity (hardware attestation, device-bound tokens).
export 'src/shield/shield_service.dart' show NexusShield, NexusShieldToken, NexusShieldClient;
export 'src/voice/voice_models.dart'
    show NexusCall, NexusJoinToken, CallQualitySample, VoiceCallState, VoiceCallStateX, VoiceEndpointType, VoiceCallDirection;
export 'src/voice/voice_engine.dart' show NexusVoiceEngine, VoiceEngineState, NoopVoiceEngine;
export 'src/voice/callkit.dart' show NexusCallKit, CallKitAction, CallKitActionType, NoopCallKit;
export 'src/voice/callkit_native.dart' show showNexusIncomingCall;
export 'src/voice/voice_overlay.dart' show NexusVoiceOverlay;
export 'src/voice/ivr.dart' show NexusIvrOverlay, NexusIvrSession, NexusIvrStatus;
export 'src/inapp/inapp_models.dart'
    show NexusInAppMessage, NexusInAppButton, NexusInAppAction;
export 'src/inapp/inapp_design.dart'
    show
        NexusInAppDesign,
        NexusInAppFrame,
        NexusInAppClose,
        NexusInAppTap,
        NexusInAppBlock,
        NexusInAppImageBlock,
        NexusInAppBadgeBlock,
        NexusInAppHeadingBlock,
        NexusInAppTextBlock,
        NexusInAppButtonsBlock,
        NexusInAppSpacerBlock,
        NexusInAppDividerBlock,
        NexusInAppCarouselBlock,
        NexusInAppCarouselCard,
        NexusInAppDesignButton;
export 'src/inapp/inapp_view.dart' show NexusInAppView;
export 'src/inapp/inapp_designed_view.dart' show NexusInAppDesignedView;
export 'src/inapp/inapp_overlay.dart' show NexusInAppOverlay, NexusInAppBuilder;

// Advanced: native platform surface (device info + replay capture).
// DocStore — the document database.
export 'src/docstore/docstore.dart' show NexusDocStore;
export 'src/docstore/client.dart' show DocStoreOptions, DocStoreException, DocStoreTokenProvider;
export 'src/docstore/api.dart'
    show DocStore, CollectionReference, DocumentReference, Query, DocumentSnapshot, QuerySnapshot, DocumentChange, DocumentChangeType, DocumentVersion, FieldValue, Filter, AggregateField, AggregateGroup, WriteBatch, Transaction;
export 'src/docstore/live.dart' show LiveStatus;
export 'src/docstore/offline.dart'
    show OfflineStore, DocStoreStorage, MemoryDocStoreStorage, SharedPreferencesDocStoreStorage, OfflineConflict, SyncStatus, LocalSnapshot, LocalQuery, LocalCollection, LocalDocumentRef;
export 'src/docstore/storage_file.dart' if (dart.library.js_interop) 'src/docstore/storage_file_stub.dart' show FileDocStoreStorage;
export 'src/docstore/core.dart' show LocalQueryException;
export 'nexus_platform_interface.dart' show NexusPlatform;
