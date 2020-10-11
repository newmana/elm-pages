module Pages.Internal.Platform.Cli exposing
    ( Content
    , Flags
    , Model
    , Msg(..)
    , Page
    , cliApplication
    , init
    , update
    )

import BuildError exposing (BuildError)
import Codec exposing (Codec)
import Dict exposing (Dict)
import Dict.Extra
import ElmHtml.InternalTypes exposing (decodeElmHtml)
import ElmHtml.ToString exposing (FormatOptions, defaultFormatOptions, nodeToStringWithOptions)
import Head
import Html exposing (Html)
import Http
import Json.Decode as Decode
import Json.Encode
import Pages.ContentCache as ContentCache exposing (ContentCache)
import Pages.Document
import Pages.Http
import Pages.Internal.ApplicationType as ApplicationType
import Pages.Internal.Platform.Effect as Effect exposing (Effect)
import Pages.Internal.Platform.Mode as Mode exposing (Mode)
import Pages.Internal.Platform.StaticResponses as StaticResponses exposing (StaticResponses)
import Pages.Internal.Platform.ToJsPayload as ToJsPayload exposing (ToJsPayload)
import Pages.Internal.StaticHttpBody as StaticHttpBody
import Pages.Manifest as Manifest
import Pages.PagePath as PagePath exposing (PagePath)
import Pages.StaticHttp as StaticHttp exposing (RequestDetails)
import Pages.StaticHttpRequest as StaticHttpRequest
import SecretsDict exposing (SecretsDict)
import TerminalText as Terminal
import Url


type alias FileToGenerate =
    { path : List String
    , content : String
    }


type alias Page metadata view pathKey =
    { metadata : metadata
    , path : PagePath pathKey
    , view : view
    }


type alias Content =
    List ( List String, { extension : String, frontMatter : String, body : Maybe String } )


type alias Flags =
    Decode.Value


type alias Model =
    { staticResponses : StaticResponses
    , secrets : SecretsDict
    , errors : List BuildError
    , allRawResponses : Dict String (Maybe String)
    , mode : Mode
    , pendingRequests : List { masked : RequestDetails, unmasked : RequestDetails }
    }


type Msg
    = GotStaticHttpResponse { request : { masked : RequestDetails, unmasked : RequestDetails }, response : Result Pages.Http.Error String }


type alias Config pathKey userMsg userModel metadata view =
    { init :
        Maybe
            { path : PagePath pathKey
            , query : Maybe String
            , fragment : Maybe String
            }
        -> ( userModel, Cmd userMsg )
    , update : userMsg -> userModel -> ( userModel, Cmd userMsg )
    , subscriptions : userModel -> Sub userMsg
    , view :
        List ( PagePath pathKey, metadata )
        ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
        ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
    , document : Pages.Document.Document metadata view
    , content : Content
    , toJsPort : Json.Encode.Value -> Cmd Never
    , fromJsPort : Sub Decode.Value
    , manifest : Manifest.Config pathKey
    , generateFiles :
        List
            { path : PagePath pathKey
            , frontmatter : metadata
            , body : String
            }
        ->
            StaticHttp.Request
                (List
                    (Result String
                        { path : List String
                        , content : String
                        }
                    )
                )
    , canonicalSiteUrl : String
    , pathKey : pathKey
    , onPageChange :
        Maybe
            ({ path : PagePath pathKey
             , query : Maybe String
             , fragment : Maybe String
             }
             -> userMsg
            )
    }


cliApplication :
    (Msg -> msg)
    -> (msg -> Maybe Msg)
    -> (Model -> model)
    -> (model -> Maybe Model)
    -> Config pathKey userMsg userModel metadata view
    -> Platform.Program Flags model msg
cliApplication cliMsgConstructor narrowMsg toModel fromModel config =
    let
        contentCache =
            ContentCache.init config.document config.content Nothing

        siteMetadata =
            contentCache
                |> Result.map
                    (\cache -> cache |> ContentCache.extractMetadata config.pathKey)
                |> Result.mapError (List.map Tuple.second)
    in
    Platform.worker
        { init =
            \flags ->
                init toModel contentCache siteMetadata config flags
                    |> Tuple.mapSecond (perform cliMsgConstructor config.toJsPort)
        , update =
            \msg model ->
                case ( narrowMsg msg, fromModel model ) of
                    ( Just cliMsg, Just cliModel ) ->
                        update siteMetadata config cliMsg cliModel
                            |> Tuple.mapSecond (perform cliMsgConstructor config.toJsPort)
                            |> Tuple.mapFirst toModel

                    _ ->
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


viewRenderer : Html msg -> String
viewRenderer html =
    let
        options =
            { defaultFormatOptions | newLines = False, indent = 0 }
    in
    viewDecoder options html


viewDecoder : FormatOptions -> Html msg -> String
viewDecoder options viewHtml =
    case
        Decode.decodeValue
            (decodeElmHtml (\_ _ -> Decode.succeed ()))
            (asJsonView viewHtml)
    of
        Ok str ->
            nodeToStringWithOptions options str

        Err err ->
            "Error: " ++ Decode.errorToString err


asJsonView : Html msg -> Decode.Value
asJsonView x =
    Json.Encode.string "REPLACE_ME_WITH_JSON_STRINGIFY"


perform : (Msg -> msg) -> (Json.Encode.Value -> Cmd Never) -> Effect pathKey -> Cmd msg
perform cliMsgConstructor toJsPort effect =
    case effect of
        Effect.NoEffect ->
            Cmd.none

        Effect.SendJsData value ->
            value
                |> Codec.encoder ToJsPayload.toJsCodec
                |> toJsPort
                |> Cmd.map never

        Effect.Batch list ->
            list
                |> List.map (perform cliMsgConstructor toJsPort)
                |> Cmd.batch

        Effect.FetchHttp ({ unmasked, masked } as requests) ->
            -- let
            --     _ =
            --         Debug.log "Fetching" masked.url
            -- in
            Http.request
                { method = unmasked.method
                , url = unmasked.url
                , headers = unmasked.headers |> List.map (\( key, value ) -> Http.header key value)
                , body =
                    case unmasked.body of
                        StaticHttpBody.EmptyBody ->
                            Http.emptyBody

                        StaticHttpBody.StringBody contentType string ->
                            Http.stringBody contentType string

                        StaticHttpBody.JsonBody value ->
                            Http.jsonBody value
                , expect =
                    Pages.Http.expectString
                        (\response ->
                            (GotStaticHttpResponse >> cliMsgConstructor)
                                { request = requests
                                , response = response
                                }
                        )
                , timeout = Nothing
                , tracker = Nothing
                }

        Effect.SendSinglePage info ->
            Json.Encode.object
                [ ( "html", Json.Encode.string info.html )
                , ( "contentJson", Json.Encode.dict identity Json.Encode.string info.contentJson )
                ]
                |> toJsPort
                |> Cmd.map never


flagsDecoder :
    Decode.Decoder
        { secrets : SecretsDict
        , mode : Mode
        , staticHttpCache : Dict String (Maybe String)
        }
flagsDecoder =
    Decode.map3
        (\secrets mode staticHttpCache ->
            { secrets = secrets
            , mode = mode
            , staticHttpCache = staticHttpCache
            }
        )
        (Decode.field "secrets" SecretsDict.decoder)
        (Decode.field "mode" Mode.modeDecoder)
        (Decode.field "staticHttpCache"
            (Decode.dict
                (Decode.string
                    |> Decode.map Just
                )
            )
        )


init :
    (Model -> model)
    -> ContentCache.ContentCache metadata view
    -> Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Config pathKey userMsg userModel metadata view
    -> Decode.Value
    -> ( model, Effect pathKey )
init toModel contentCache siteMetadata config flags =
    case Decode.decodeValue flagsDecoder flags of
        Ok { secrets, mode, staticHttpCache } ->
            case mode of
                --Mode.ElmToHtmlBeta ->
                --    elmToHtmlBetaInit { secrets = secrets, mode = mode, staticHttpCache = staticHttpCache } toModel contentCache siteMetadata config flags
                --
                _ ->
                    initLegacy { secrets = secrets, mode = mode, staticHttpCache = staticHttpCache } toModel contentCache siteMetadata config flags

        Err error ->
            updateAndSendPortIfDone
                config
                siteMetadata
                (Model StaticResponses.error
                    SecretsDict.masked
                    [ { title = "Internal Error"
                      , message = [ Terminal.text <| "Failed to parse flags: " ++ Decode.errorToString error ]
                      , fatal = True
                      }
                    ]
                    Dict.empty
                    Mode.Dev
                    []
                )
                toModel


elmToHtmlBetaInit { secrets, mode, staticHttpCache } toModel contentCache siteMetadata config flags =
    --case flags of
    --init toModel contentCache siteMetadata config flags
    --|> Tuple.mapSecond (perform cliMsgConstructor config.toJsPort)
    --|> Tuple.mapSecond
    --    (\cmd ->
    --Cmd.map AppMsg
    --Cmd.none
    ( toModel
        (Model StaticResponses.error
            secrets
            []
            --(metadataParserErrors |> List.map Tuple.second)
            staticHttpCache
            mode
            []
        )
    , Effect.NoEffect
      --, { html =
      --        Html.div []
      --            [ Html.text "Hello!!!!!" ]
      --            |> viewRenderer
      --  }
      --    |> Effect.SendSinglePage
    )



--)


initLegacy { secrets, mode, staticHttpCache } toModel contentCache siteMetadata config flags =
    case contentCache of
        Ok _ ->
            case ContentCache.pagesWithErrors contentCache of
                [] ->
                    let
                        requests =
                            Result.andThen
                                (\metadata ->
                                    staticResponseForPage metadata config.view
                                )
                                siteMetadata

                        staticResponses : StaticResponses
                        staticResponses =
                            case requests of
                                Ok okRequests ->
                                    StaticResponses.init staticHttpCache siteMetadata config okRequests

                                Err errors ->
                                    -- TODO need to handle errors better?
                                    StaticResponses.init staticHttpCache siteMetadata config []
                    in
                    StaticResponses.nextStep config siteMetadata mode secrets staticHttpCache [] staticResponses
                        |> nextStepToEffect config (Model staticResponses secrets [] staticHttpCache mode [])
                        |> Tuple.mapFirst toModel

                pageErrors ->
                    let
                        requests =
                            Result.andThen
                                (\metadata ->
                                    staticResponseForPage metadata config.view
                                )
                                siteMetadata

                        staticResponses : StaticResponses
                        staticResponses =
                            case requests of
                                Ok okRequests ->
                                    StaticResponses.init staticHttpCache siteMetadata config okRequests

                                Err errors ->
                                    -- TODO need to handle errors better?
                                    StaticResponses.init staticHttpCache siteMetadata config []
                    in
                    updateAndSendPortIfDone
                        config
                        siteMetadata
                        (Model
                            staticResponses
                            secrets
                            pageErrors
                            staticHttpCache
                            mode
                            []
                        )
                        toModel

        Err metadataParserErrors ->
            updateAndSendPortIfDone
                config
                siteMetadata
                (Model StaticResponses.error
                    secrets
                    (metadataParserErrors |> List.map Tuple.second)
                    staticHttpCache
                    mode
                    []
                )
                toModel


updateAndSendPortIfDone :
    Config pathKey userMsg userModel metadata view
    -> Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Model
    -> (Model -> model)
    -> ( model, Effect pathKey )
updateAndSendPortIfDone config siteMetadata model toModel =
    StaticResponses.nextStep
        config
        siteMetadata
        model.mode
        model.secrets
        model.allRawResponses
        model.errors
        model.staticResponses
        |> nextStepToEffect config model
        |> Tuple.mapFirst toModel


update :
    Result (List BuildError) (List ( PagePath pathKey, metadata ))
    -> Config pathKey userMsg userModel metadata view
    -> Msg
    -> Model
    -> ( Model, Effect pathKey )
update siteMetadata config msg model =
    case msg of
        GotStaticHttpResponse { request, response } ->
            let
                -- _ =
                --     Debug.log "Got response" request.masked.url
                --
                updatedModel =
                    (case response of
                        Ok okResponse ->
                            { model
                                | pendingRequests =
                                    model.pendingRequests
                                        |> List.filter (\pending -> pending /= request)
                            }

                        Err error ->
                            { model
                                | errors =
                                    List.append
                                        model.errors
                                        [ { title = "Static HTTP Error"
                                          , message =
                                                [ Terminal.text "I got an error making an HTTP request to this URL: "

                                                -- TODO include HTTP method, headers, and body
                                                , Terminal.yellow <| Terminal.text request.masked.url
                                                , Terminal.text "\n\n"
                                                , case error of
                                                    Pages.Http.BadStatus metadata body ->
                                                        Terminal.text <|
                                                            String.join "\n"
                                                                [ "Bad status: " ++ String.fromInt metadata.statusCode
                                                                , "Status message: " ++ metadata.statusText
                                                                , "Body: " ++ body
                                                                ]

                                                    Pages.Http.BadUrl _ ->
                                                        -- TODO include HTTP method, headers, and body
                                                        Terminal.text <| "Invalid url: " ++ request.masked.url

                                                    Pages.Http.Timeout ->
                                                        Terminal.text "Timeout"

                                                    Pages.Http.NetworkError ->
                                                        Terminal.text "Network error"
                                                ]
                                          , fatal = True
                                          }
                                        ]
                            }
                    )
                        |> StaticResponses.update
                            -- TODO for hash pass in RequestDetails here
                            { request = request
                            , response = Result.mapError (\_ -> ()) response
                            }
            in
            StaticResponses.nextStep config
                siteMetadata
                updatedModel.mode
                updatedModel.secrets
                updatedModel.allRawResponses
                updatedModel.errors
                updatedModel.staticResponses
                |> nextStepToEffect config updatedModel


nextStepToEffect : Config pathKey userMsg userModel metadata view -> Model -> StaticResponses.NextStep pathKey -> ( Model, Effect pathKey )
nextStepToEffect config model nextStep =
    case nextStep of
        StaticResponses.Continue updatedAllRawResponses httpRequests ->
            let
                nextAndPending =
                    model.pendingRequests ++ httpRequests

                doNow =
                    nextAndPending

                pending =
                    []
            in
            ( { model | allRawResponses = updatedAllRawResponses, pendingRequests = pending }
            , doNow
                |> List.map Effect.FetchHttp
                |> Effect.Batch
            )

        StaticResponses.Finish toJsPayload ->
            case model.mode of
                Mode.ElmToHtmlBeta ->
                    let
                        contentCache =
                            ContentCache.init config.document config.content Nothing

                        siteMetadata =
                            contentCache
                                |> Result.map
                                    (\cache -> cache |> ContentCache.extractMetadata config.pathKey)
                                |> Result.mapError (List.map Tuple.second)

                        currentPage : { path : PagePath pathKey, frontmatter : metadata }
                        currentPage =
                            siteMetadata
                                |> Result.withDefault []
                                |> singleItemOrCrash
                                |> (\( path, frontmatter ) ->
                                        { path = path, frontmatter = frontmatter }
                                   )

                        singleItemOrCrash : List a -> a
                        singleItemOrCrash list =
                            case list of
                                [ item ] ->
                                    item

                                _ ->
                                    todo "Expected exactly one item."

                        renderedView : { title : String, body : Html userMsg }
                        renderedView =
                            viewRequest
                                |> makeItWork

                        --viewFnResult =
                        --    --currentPage
                        --         config.view siteMetadata currentPage
                        --            --(contentCache
                        --            --    |> Result.map (ContentCache.extractMetadata pathKey)
                        --            --    |> Result.withDefault []
                        --            -- -- TODO handle error better
                        --            --)
                        --        |> (\request ->
                        --                StaticHttpRequest.resolve ApplicationType.Browser request viewResult.staticData
                        --           )
                        makeItWork :
                            StaticHttp.Request
                                { view :
                                    userModel
                                    -> view
                                    -> { title : String, body : Html userMsg }
                                , head : List (Head.Tag pathKey)
                                }
                            -> { title : String, body : Html userMsg }
                        makeItWork request =
                            case StaticHttpRequest.resolve ApplicationType.Browser request (staticData |> Dict.map (\k v -> Just v)) of
                                Err error ->
                                    todo (toString error)

                                Ok functions ->
                                    let
                                        pageModel : userModel
                                        pageModel =
                                            config.init
                                                (Just
                                                    { path = currentPage.path
                                                    , query = Nothing
                                                    , fragment = Nothing
                                                    }
                                                )
                                                |> Tuple.first

                                        fakeUrl =
                                            { protocol = Url.Https
                                            , host = ""
                                            , port_ = Nothing
                                            , path = "" -- TODO
                                            , query = Nothing
                                            , fragment = Nothing
                                            }

                                        urls =
                                            { currentUrl = fakeUrl
                                            , baseUrl = fakeUrl
                                            }

                                        pageView : view
                                        pageView =
                                            case ContentCache.lookup config.pathKey contentCache urls of
                                                Just ( pagePath, entry ) ->
                                                    case entry of
                                                        ContentCache.Parsed frontmatter viewResult ->
                                                            expectOk viewResult.body

                                                        _ ->
                                                            todo "Unhandled content cache state"

                                                _ ->
                                                    todo "Unhandled content cache state"
                                    in
                                    functions.view pageModel pageView

                        staticData =
                            case toJsPayload of
                                ToJsPayload.Success value ->
                                    value.pages
                                        |> Dict.values
                                        |> List.head
                                        --|> log "@@@ 1"
                                        |> Maybe.withDefault Dict.empty

                                _ ->
                                    todo "Unhandled"

                        viewRequest :
                            StaticHttp.Request
                                { view :
                                    userModel
                                    -> view
                                    -> { title : String, body : Html userMsg }
                                , head : List (Head.Tag pathKey)
                                }
                        viewRequest =
                            config.view (siteMetadata |> Result.withDefault []) currentPage
                    in
                    case siteMetadata of
                        Ok [ ( page, metadata ) ] ->
                            ( model
                            , --{ html =
                              --        Html.div []
                              --            [ Html.text "Hello!!!!!" ]
                              --            |> viewRenderer
                              --  }
                              { route = page |> PagePath.toString
                              , contentJson =
                                    case toJsPayload of
                                        ToJsPayload.Success value ->
                                            value.pages
                                                |> Dict.values
                                                |> List.head
                                                --|> Debug.log "@@@ 1"
                                                |> Maybe.withDefault Dict.empty

                                        _ ->
                                            Dict.empty

                              --|> Debug.log "@@@ 2"
                              , html =
                                    --Html.div []
                                    --[ Html.text "Hello!!!!!" ]
                                    renderedView.body
                                        |> viewRenderer
                              , errors = []
                              }
                                |> Effect.SendSinglePage
                            )

                        Ok things ->
                            todo (toString things)

                        --( model, Effect.NoEffect )
                        Err error ->
                            todo (toString error)

                _ ->
                    ( model, Effect.SendJsData toJsPayload )


toString value =
    --Debug.toString value
    "toString"


todo value =
    --Debug.todo value
    todo value


expectOk : Result err value -> value
expectOk result =
    case result of
        Ok value ->
            value

        Err error ->
            todo (toString error)


staticResponseForPage :
    List ( PagePath pathKey, metadata )
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttpRequest.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
        )
    ->
        Result (List BuildError)
            (List
                ( PagePath pathKey
                , StaticHttp.Request
                    { view : userModel -> view -> { title : String, body : Html userMsg }
                    , head : List (Head.Tag pathKey)
                    }
                )
            )
staticResponseForPage siteMetadata viewFn =
    siteMetadata
        |> List.map
            (\( pagePath, frontmatter ) ->
                let
                    thing =
                        viewFn siteMetadata
                            { path = pagePath
                            , frontmatter = frontmatter
                            }
                in
                Ok ( pagePath, thing )
            )
        |> combine


combine : List (Result error ( key, success )) -> Result (List error) (List ( key, success ))
combine list =
    list
        |> List.foldr resultFolder (Ok [])


resultFolder : Result error a -> Result (List error) (List a) -> Result (List error) (List a)
resultFolder current soFarResult =
    case soFarResult of
        Ok soFarOk ->
            case current of
                Ok currentOk ->
                    currentOk
                        :: soFarOk
                        |> Ok

                Err error ->
                    Err [ error ]

        Err soFarErr ->
            case current of
                Ok currentOk ->
                    Err soFarErr

                Err error ->
                    error
                        :: soFarErr
                        |> Err
