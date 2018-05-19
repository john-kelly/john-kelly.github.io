module Main exposing (main)

import Browser
import Html
import Markdown


main : Program () () ()
main =
    Browser.fullscreen
        { init = \env -> ( (), Cmd.none )
        , view =
            \model ->
                { title = "foldp"
                , body =
                    [ Markdown.toHtmlWith
                        { githubFlavored = Just { tables = True, breaks = True }
                        , defaultHighlighting = Just "elm"
                        , sanitize = False
                        , smartypants = False
                        }
                        []
                        blog0
                    ]
                }
        , update = \msg model -> ( model, Cmd.none )
        , onNavigation = Nothing
        , subscriptions = \model -> Sub.none
        }


blog0 =
    """
---
title: "A Remote Data Request API in Elm"
published: true
description: An overview of a remote data request API in Elm
tags: elm, api, postgrest, webdev
---

*This post is about the core abstractions found in the elm-postgrest package and how those abstractions may be relevant to similar packages.*

---

In Elm, the design space of **remote data request APIs** has seen its fair share of work.

We have APIs like `lukewestby/elm-http-builder` which provide a thin convenience layer over `elm-lang/http`.
```elm
addItem : String -> Cmd Msg
addItem item =
    HttpBuilder.post "http://example.com/api/items"
        |> withQueryParams [ ("hello", "world") ]
        |> withHeader "X-My-Header" "Some Header Value"
        |> withJsonBody (itemEncoder item)
        |> withTimeout (10 * Time.second)
        |> withExpect (Http.expectJson itemsDecoder)
        |> withCredentials
        |> send handleRequestComplete
```

We have APIs like `krisajenkins/remotedata` which model the various states remote data can take.
```elm
type RemoteData e a
    = NotAsked
    | Loading
    | Failure e
    | Success a
```

And, we have APIs like `jamesmacaulay/elm-graphql`, `jahewson/elm-graphql`, `dillonkearns/graphqelm`, `mgold/elm-data`, `noahzgordon/elm-jsonapi`, and others which abstract over `elm-lang/http` to provide an API which is nice in the domain language of their respective specification. We'll refer to this group of APIs as *backend specific request builders*.

In addition to community efforts, Evan himself wrote up [a vision for data interchange in Elm](https://gist.github.com/evancz/1c5f2cf34939336ecb79b97bb89d9da6). And although the API for this specific vision likely sits on the same level of abstraction as `elm-lang/http`, `Json.Decode`, and `Json.Encode` rather than backend specific request builders, it legitimized the exploration around "how do you send information between clients and servers?"

# Design Space
What is in the design space of remote data request APIs? More specifically, what is in the design space of backend specific request builders?

For the sake of this post, we'll define the design space as:

---------

A means to **describe the capabilities of a data model** and subsequently **build requests against that data model** for client-server applications.

---------

With the following design goals:

- **Domain Language vs HTTP** - We want to interact with our backends in their own terms rather than their raw transfer protocol. For example, in the context of GraphQL, this means queries, mutations, selection sets, fragments, etc.
- **Selections vs Decoders** - We want to speak in terms of what we wish to select rather than how we wish to decode it.
- **Resources vs JSON** - We want to speak in terms of the abstract representation of our data model rather than its specific interchange format and/or storage format.
- **Typed vs Untyped** - We want to compose our requests using the values of our application rather than the concatenation of query strings.

Let's take a second look at these design goals but this time in the form of a diagram:
<table>
   <tr>
      <th>Request Builder</th>
      <th>Schema Description</th>
   </tr>
   <tr>
      <td>CRUD requests <br> selections <br> conditions <br> order <br> limit and offset <br> pagination</td>
      <td>resource schema<br>attributes<br>relationships<br>cardinality</td>
   </tr>
   <tr>
      <td colspan=2>
         <center><i>Abstraction Barrier</i></center>
      </td>
   </tr>
   <tr>
      <th>Transfer Protocol</th>
      <th>Interchange Format</th>
   </tr>
   <tr>
      <td>HTTP:<br>headers<br>body<br>methods<br>url: query and fragment<br>status codes</td>
      <td>json<br>edn<br>xml<br>transit<br>protobuf</td>
   </tr>
</table>

The dividing horizontal line in the diagram represents an *abstraction barrier*. The barrier, in this case, separates backend specific request builders (above) from their implementation (below). Users at one layer should not need to concern themselves with the details below. The remainder of this post will examine an Elm API at the abstraction level of backend specific request builder.

# elm-postgrest
I'm the author of `john-kelly/elm-postgrest`; a package that abstracts over `elm-lang/http`, `Json.Decode`, and `Json.Encode` to provide a nice API in the context of PostgREST. Like previously stated, this package falls into the category of backend specific request builders.

This post is about the core abstractions found in the elm-postgrest package and how those abstractions may be relevant to similar packages. All examples will be based on the work from `john-kelly/elm-postgrest-spa-example`, which is an almost complete port of `rtfeldman/elm-spa-example` to PostgREST. For those unfamiliar with PostgREST, here's an excerpt from their official documentation:

> PostgREST is a standalone web server that turns your PostgreSQL database directly into a RESTful API. The structural constraints and permissions in the database determine the API endpoints and operations ... The PostgREST philosophy establishes a single declarative source of truth: the data itself.

The mental model for how these 3 pieces fit together:

-------

#### elm-postgrest (client) ⇄ PostgREST (server) ⇄ PostgreSQL (db)

-------

*In case you're wondering, no knowledge of PostgREST is necessary to make it through this post, however, intermediate knowledge of Elm and technologies like REST, GraphQL, JSON API, Firebase, Parse, or other remote data server specifications will be helpful.*

Alright. Now that we have some context, let's dig into the code.

# Our First Request
Our first request will retrieve all articles from our remote data server.

For this example, we'll assume that we have a collection of article resources at `example.com/api/articles`. Each article has a title, a body, and the count of the number of favorites.

*I take a top down approach for the code in this example. Keep this in mind! Later sections will help you better understand earlier sections.*

## Types
We're going to start out by looking at 4 of the core types in elm-postgrest. I provide the internal implementation of each type, however, don't get bogged down in the definition. I show the implementation in an attempt to ground the new PostgRest types to something you're familiar with.

```elm
import PostgRest as PG
    exposing
        ( Request
        , Selection
        , Schema
        , Attribute
        )
```
- **Request** - A fully constructed request. The only thing left to do is convert this value into an `Http.Request` and send it off to the Elm runtime. As we'll learn, a `Request` can be constructed with a `Selection` and a `Schema`.
```elm
type Request a
    = Read
        { parameters : Parameters
        , decoder : Decode.Decoder a
        }
```
- **Selection** - The `Selection` is one of the primary means to build requests against the data model. Specifically, the `Selection` represents which fields to select and which related resources to embed.
```elm
type Selection attributes a
    = Selection
        (attributes
         ->
            { attributeNames : List String
            , embeds : List Parameters
            , decoder : Decode.Decoder a
            }
        )
```
- **Schema** - The `Schema` is the means to describe the capabilities of a data model. *Capabilities* means what we can select, what we can filter by, and what we can order by. We're only going to cover selection in this post.
```elm
type Schema id attributes
    = Schema String attributes
```
- **Attribute** - An individual select-able unit of a `Schema`. For example, the article resource has a title `Attribute String`.
```elm
type Attribute a
    = Attribute
        { name : String
        , decoder : Decode.Decoder a
        , encoder : a -> Encode.Value
        , urlEncoder : a -> String
        }
```

## Request
Here we're constructing a `Request` which will result in a `List String`. The mental model for this type should be the same as that of an `Http.Request`: "If we were to send this `Request`, we can expect back a `List String`."


```elm
getArticles : Request (List String)
getArticles =
    PG.readAll articleSchema articleSelection
```
Let's take a look at the function signature of `PG.readAll` before moving on to the next section.

```elm
readAll : Schema id attributes -> Selection attributes a -> Request (List a)
```

As we can see by the signature of `readAll`, a `Request` can be constructed with a `Selection` and a `Schema`. Let's now take a look at our `Selection`.

## Selection

The `Selection` type has 2 type parameters: `attributes` and `a`. The mental model for reading this type is "If given a `Schema` of `attributes`, a value of type `a` could be selected."

```elm
articleSelection :
    Selection
        { attributes
            | title : Attribute String
        }
        String
articleSelection =
    PG.field .title
```

Things will look vaguely familiar if you've worked with `Json.Decode.field`. This is intentional. Overall, you'll find that the `Selection` API is quite similar to the `Decoder` API. Let's examine the signature of `PG.field`:

```elm
PG.field : (attributes -> Attribute a) -> Selection attributes a
```

A field `Selection` is composed of a dot accessor for an `Attribute`. If we remember back to the mental model for a `Selection`, we'll recall that we're in need of a `Schema` to fulfill the `Selection`. Given that the first type parameter of our `articleSelection` is `{ attributes | title : Attribute String }`, our `Schema` will likely itself have this record of `Attribute`s. Let's take a look!

## Schema

In theory, we could pass anything as the second parameter to the `PG.schema` function, but in practice this value will always be an Elm record of `Attribute`s.

```elm
articleSchema :
    Schema x
        { title : Attribute String
        , body : Attribute String
        , favoritesCount : Attribute Int
        }
articleSchema =
    PG.schema "articles"
        { title = PG.string "title"
        , body = PG.string "body"
        , favoritesCount = PG.int "favorites_count"
        }
```

`PG.schema` takes a `String` which corresponds to the path to our resource (ex: example.com/api/*articles*) and a record of `Attribute`s. This record of `Attribute`s describes the capabilities of a data model. In our specific case, it describes what we are able to select!

Let's take a look at how `Schema` and `PG.schema` are defined internally:

```elm
type Schema id attributes
    = Schema String attributes

schema : String -> attributes -> Schema id attributes
schema name attrs =
    Schema name attrs
```

At first glance, we'll see that a `Schema` is nothing more than a wrapper around a record of `Attribute`s. And this is true, but it's important to highlight that it's an **opaque** wrapper around a record of `Attribute`s. It may not be immediately obvious, but it is this API that guides users towards a separation of the description of capabilities (`Schema`) from the building of requests (`Selection`). A user can't just write something like `PG.field mySchema.title` because the record is wrapped, and a user can't just unwrap the `Schema` because it's opaque! They are forced to use the functions provided by the package to compose things (namely `PG.field`). This API guides users towards writing selections in terms of an eventual record of attributes!

*Hopefully the previous explanation sheds a bit of light on why `PG.field` takes a dot accessor for an `Attribute` rather than an `Attribute` directly.*

Before moving on, let's review a few of these type signatures side by side:
```elm
PG.readAll : Schema id attributes -> Selection attributes a -> Request (List a)


articleSelection :
    Selection
        { attributes
            | title : Attribute String
        }
        String


articleSchema :
    Schema x
        { title : Attribute String
        , body : Attribute String
        , favoritesCount : Attribute Int
        }
```

Just take a moment to take this all in. It's pretty cool how the pieces fit together, and we can thank Elm's extensible record system for that!

*Just to wrap things up for those who are curious, there exists a function of type `PG.toHttpRequest : PG.Request -> Http.Request`. From there you can convert to a `Task` with `Http.toTask` or directly to a `Cmd` with `Http.send`.*

# Conclusion

### Did we meet our design goals?
Yes! In our example, we built a request to read all the titles (Request Builder) of our article collection resource (Schema Representation) as opposed to making an HTTP GET request to the `api/articles?select=title` URL (Transfer Protocol) and decoding the JSON response (Interchange Format). The former is how we expressed our request in the example, and the latter is an implementation detail.

### What has this design bought us?

1. **Type Safety**
2. **Reuse**

#### Type Safety
If the `Schema` is valid, our `Request` will be valid. Our `Selection` is defined *in terms of* a `Schema`, and we can only construct a `Request` if the `Schema` and `Selection` agree statically. Put another way, a subset of request building errors become static errors rather than logic errors.

For example, let's say we mistype `.title` when we're constructing our `Selection`. If our `Schema` correctly describes our remote resource, we'll get a nice compiler message. Let's take a look at that error message!

```
The definition of `articleSelection` does not match its type annotation.

18| articleSelection :
19|     Selection
20|         { attributes
21|             | title : Attribute String
22|         }
23|         String
24| articleSelection =
25|>    PG.field .titl

The type annotation for `articleSelection` says it is a:

    Selection { attributes | title : ... } String

But the definition (shown above) is a:

    Selection { b | titl : ... } a
```

Pretty cool. However...

Close readers will argue that we've just moved the logic error to the `Schema` from the `Decoder`. This is true, however, the difference is that we only have 1 `Schema` for an entire entity as opposed to a `Decoder` for each way we wish to decode the entity. A `Schema` represents a single source of truth for all `Selection` capabilities of a remote resource. This in turn reduces the surface area of decoding logic errors.

So, in summary: If the `Schema` is valid, our `Request` will be valid.


#### Reuse

A `Selection` can be reused to construct `Request`s with *any* `Schema` that has the proper `Attribute`s! For example, if our remote data server had both article resources and book resources:

```elm
articleSchema :
    Schema x
        { title : Attribute String
        , body : Attribute String
        , favoritesCount : Attribute Int
        }
articleSchema =
    PG.schema "articles"
        { title = PG.string "title"
        , body = PG.string "body"
        , favoritesCount = PG.int "favorites_count"
        }


bookSchema :
    Schema x
        { title : Attribute String
        , pages : Attribute Int
        , authorName : Attribute String
        }
bookSchema =
    PG.schema "books"
        { title = PG.string "title"
        , pages = PG.int "pages"
        , authorName = PG.string "author_name"
        }
```

We could use the same `Selection`:

```elm
titleSelection :
    Selection
        { attributes
            | title : Attribute String
        }
        String
titleSelection =
    PG.field .title
```

To construct our 2 separate requests:

```elm
getArticles : Request (List String)
getArticles =
    PG.readAll articleSchema titleSelection

getBooks : Request (List String)
getBooks =
    PG.readAll bookSchema titleSelection
```

Pretty cool. However...

To be completely honest, I have not yet had a need for this reuse feature. With that being said, there's still something about it that makes the API feel right.

So, in summary: Extensible records in `Selection` API grant us reuse.


### Which ideas could find their way into similar projects?
- `Schema` as single source of truth for `Selection` capabilities
- Separation of `Schema` and `Selection`
- Extensible records central to design of this separation
- `Selection` API similar to that of `Decoder` API
- And more.. we'll discuss those in the future posts

# Future
In the interest of space, time and boredom, I have not included all of the API designs of the `elm-postgrest` package in this post. In the future, I may write posts to highlight the concepts which were left out here. For example:
- Combining Selections
- Schema Relationships and Embedding Selections
- Conditions and Orders
- Create, Update, and Delete


Thanks for reading.


*If you'd like to view some more simple examples, here's a link to [the examples on github](https://github.com/john-kelly/elm-postgrest-example). Take a look at each individual git commit.*

*If you'd like to see a more "RealWorld" example application, here's a link to [john-kelly/elm-postgrest-spa-example](https://github.com/john-kelly/elm-postgrest-spa-example).*

*If you're interested in taking a look at the development of `john-kelly/elm-postgrest`, head over to the [dev branch](https://github.com/john-kelly/elm-postgrest/tree/dev).*

"""
