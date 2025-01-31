module Pages.SiteConfig exposing (SiteConfig)

import DataSource exposing (DataSource)
import Head
import Pages.Manifest


type alias SiteConfig data =
    { data : DataSource data
    , canonicalUrl : String
    , manifest : data -> Pages.Manifest.Config
    , head : data -> List Head.Tag
    }
