module Main exposing (main)

import Browser
import Html


main : Program () () ()
main =
    Browser.fullscreen
        { init = \env -> ( (), Cmd.none )
        , view =
            \model ->
                { title = "foldp"
                , body = [ Html.text "hi" ]
                }
        , update = \msg model -> ( model, Cmd.none )
        , onNavigation = Nothing
        , subscriptions = \model -> Sub.none
        }
