module Services.Analysis.MissingRelations exposing (forTables)

import Dict exposing (Dict)
import Libs.Dict as Dict
import Libs.List as List
import Libs.Maybe as Maybe
import Libs.Nel as Nel exposing (Nel)
import Libs.String as String
import Models.Project.Column as Column exposing (Column)
import Models.Project.ColumnName exposing (ColumnName)
import Models.Project.ColumnPath as ColumnPath exposing (ColumnPath, ColumnPathStr)
import Models.Project.Relation exposing (Relation)
import Models.Project.SchemaName exposing (SchemaName)
import Models.Project.Table as Table exposing (Table)
import Models.Project.TableId exposing (TableId)
import PagesComponents.Organization_.Project_.Models.SuggestedRelation exposing (SuggestedRelation, SuggestedRelationRef)


forTables : Dict TableId Table -> List Relation -> Dict TableId (List ColumnPath) -> Dict TableId (Dict ColumnPathStr (List SuggestedRelation))
forTables tables relations ignoredRelations =
    let
        tableNames : Dict NormalizedTableName (List TableId)
        tableNames =
            tables |> Dict.keys |> List.groupBy (\( _, tableName ) -> tableName |> String.splitWords |> String.join "_")

        relationBySrc : Dict TableId (Dict ColumnPathStr (List Relation))
        relationBySrc =
            relations |> List.groupBy (.src >> .table) |> Dict.map (\_ -> List.groupBy (.src >> .column >> ColumnPath.toString))
    in
    tables
        |> Dict.map
            (\_ table ->
                let
                    ignoreColumns : List ColumnPath
                    ignoreColumns =
                        ignoredRelations |> Dict.getOrElse table.id []
                in
                table.columns
                    |> Dict.values
                    |> List.concatMap Column.flatten
                    |> List.filterNot (\c -> ignoreColumns |> List.member c.path)
                    |> List.map (\c -> ( c.path |> ColumnPath.toString, guessRelations tableNames tables relationBySrc table c ))
                    |> List.filter (Tuple.second >> List.nonEmpty)
                    |> Dict.fromList
            )
        |> Dict.filter (\_ -> Dict.nonEmpty)


type alias NormalizedTableName =
    -- tableName |> StringCase.splitWords |> String.join "_"
    String


guessRelations : Dict NormalizedTableName (List TableId) -> Dict TableId Table -> Dict TableId (Dict ColumnPathStr (List Relation)) -> Table -> { path : ColumnPath, column : Column } -> List SuggestedRelation
guessRelations tableNames tables relationBySrc table { path, column } =
    let
        colRef : SuggestedRelationRef
        colRef =
            { table = table.id, column = path, kind = column.kind }

        columnWords : List String
        columnWords =
            column.name |> String.splitWords

        targetColumnName : ColumnName
        targetColumnName =
            columnWords |> List.last |> Maybe.withDefault column.name |> String.singular
    in
    (if targetColumnName == "id" && List.length columnWords > 1 then
        let
            tableHint : List String
            tableHint =
                columnWords |> List.dropRight 1

            suggestedRelations : List SuggestedRelation
            suggestedRelations =
                getTypeColumn table path
                    |> Maybe.andThen
                        (\typeCol ->
                            typeCol.column.values
                                |> Maybe.map
                                    (Nel.toList
                                        >> List.map
                                            (\value ->
                                                { src = colRef
                                                , ref = getTargetColumn tableNames tables table.schema (value |> String.splitWords) targetColumnName
                                                , when = Just { column = typeCol.path, value = value }
                                                }
                                            )
                                        >> List.filter (\rel -> rel.ref /= Nothing)
                                    )
                        )
                    |> Maybe.withDefault [ { src = colRef, ref = getTargetColumn tableNames tables table.schema tableHint targetColumnName, when = Nothing } ]
        in
        suggestedRelations

     else if String.endsWith "id" column.name && String.length column.name > 2 then
        -- when no separator before `id`
        let
            tableHint : List String
            tableHint =
                column.name |> String.dropRight 2 |> String.splitWords
        in
        [ { src = colRef, ref = [ column.name, "id" ] |> List.findMap (getTargetColumn tableNames tables table.schema tableHint), when = Nothing } ]

     else if List.last columnWords == Just "by" then
        -- `created_by` columns should refer to a user like table
        [ { src = colRef, ref = [ [ "user" ], [ "account" ] ] |> List.findMap (\tableHint -> getTargetColumn tableNames tables table.schema tableHint "id"), when = Nothing } ]

     else
        []
    )
        |> removeKnownRelations relationBySrc table.id path


getTypeColumn : Table -> ColumnPath -> Maybe { path : ColumnPath, column : Column }
getTypeColumn table path =
    -- useful for polymorphic relations
    let
        typePath : ColumnPath
        typePath =
            path
                |> Nel.mapLast
                    (\name ->
                        if name |> String.endsWith "id" then
                            String.dropRight 2 name ++ "type"

                        else if name |> String.endsWith "ids" then
                            String.dropRight 3 name ++ "type"

                        else if name |> String.endsWith "Id" then
                            String.dropRight 2 name ++ "Type"

                        else if name |> String.endsWith "Ids" then
                            String.dropRight 3 name ++ "Type"

                        else if name |> String.endsWith "ID" then
                            String.dropRight 2 name ++ "TYPE"

                        else if name |> String.endsWith "IDS" then
                            String.dropRight 3 name ++ "TYPE"

                        else
                            name ++ "_type"
                    )
    in
    table |> Table.getColumn typePath |> Maybe.map (\c -> { path = typePath, column = c })


getTargetColumn : Dict NormalizedTableName (List TableId) -> Dict TableId Table -> SchemaName -> List String -> ColumnName -> Maybe SuggestedRelationRef
getTargetColumn tableNames tables preferredSchema tableHint targetColumnName =
    (tableHint |> String.join "_" |> getTable tableNames tables preferredSchema targetColumnName)
        |> Maybe.onNothing (\_ -> tableHint |> String.join "_" |> String.plural |> getTable tableNames tables preferredSchema targetColumnName)
        |> Maybe.onNothing (\_ -> tableHint |> List.drop 1 |> String.join "_" |> getTable tableNames tables preferredSchema targetColumnName)
        |> Maybe.onNothing (\_ -> tableHint |> List.drop 1 |> String.join "_" |> String.plural |> getTable tableNames tables preferredSchema targetColumnName)


getTable : Dict NormalizedTableName (List TableId) -> Dict TableId Table -> SchemaName -> ColumnName -> NormalizedTableName -> Maybe SuggestedRelationRef
getTable tableNames tables preferredSchema columnName tableName =
    (tableNames |> Dict.get tableName)
        |> Maybe.andThen (\ids -> ids |> List.find (\( schema, _ ) -> schema == preferredSchema) |> Maybe.orElse (ids |> List.head))
        |> Maybe.andThen (\id -> tables |> Dict.get id)
        |> Maybe.andThen (\table -> table.columns |> Dict.get columnName |> Maybe.map (\col -> { table = table.id, column = Nel columnName [], kind = col.kind }))


removeKnownRelations : Dict TableId (Dict ColumnPathStr (List Relation)) -> TableId -> ColumnPath -> List SuggestedRelation -> List SuggestedRelation
removeKnownRelations relationBySrc tableId columnPath suggestedRelations =
    let
        relations : List Relation
        relations =
            relationBySrc |> Dict.get tableId |> Maybe.andThen (Dict.get (ColumnPath.toString columnPath)) |> Maybe.withDefault []
    in
    suggestedRelations
        |> List.filter (\sr -> sr.ref /= Just sr.src)
        |> List.filter
            (\sr ->
                sr.ref
                    |> Maybe.map (\r -> { table = r.table, column = r.column })
                    |> Maybe.map (\ref -> relations |> List.any (\r -> r.ref == ref) |> not)
                    |> Maybe.withDefault (relations |> List.isEmpty)
            )
