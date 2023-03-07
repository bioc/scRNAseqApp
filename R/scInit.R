#' Create a scRNAseqApp project
#' @description To run scRNAseqApp, you need to first create a directory
#' which contains the required files.
#' @param app_path path, a directory where do you want to create the app
#' @param root character(1), the user name for administrator
#' @param password character(1), the password for administrator
#' @param datafolder the folder where saved the dataset for the app
#' @param overwrite logical(1), overwrite the `app_path` if there is
#'  a project.
#' @param app_title,app_description character(1). The title and 
#' description of the home page.
#' @return no returns. This function will copy files to `app_path`
#' @export
#' @importFrom shinymanager create_db
#' @importFrom scrypt hashPassword
#' @importFrom utils write.table
#' @examples
#' if(interactive()){
#'     scInit()
#' }

scInit <- function(
    app_path = getwd(),
    root = 'admin',
    password = 'scRNAseqApp',
    datafolder = 'data',
    overwrite = FALSE,
    app_title = 'scRNAseq Database',
    app_description = 'This database is a collection of
        single cell RNA-seq data.') {
    stopifnot(is.logical(overwrite) && length(overwrite) == 1)
    .globals$datafolder <- datafolder
    if (!dir.exists(app_path)) {
        dir.create(app_path, recursive = TRUE)
    }
    message("Now copy pbmc_small sample files")
    file.copy(
        system.file("extdata", "data", package = "scRNAseqApp"),
        to = app_path,
        recursive = TRUE,
        overwrite = overwrite
    )
    # define credentials
    credentials <- data.frame(
        user = root,
        password = hashPassword(password),
        admin = TRUE,
        is_hashed_password = TRUE,
        privilege = 'all',
        stringsAsFactors = FALSE
    )
    # Init the database
    create_db(
        credentials_data = credentials,
        sqlite_path = file.path(app_path, "database.sqlite")
    )
    # Write the doc.txt
    writeLines(c(
        paste('<h4>', app_title, '</h4>'),
        paste('<p>', app_description, '</p>')
    ),
    file.path(app_path, "doc.txt"))
    # Write the counter file
    www <- file.path(app_path, "www")
    dir.create(www)
    visitor <-
        data.frame(
            date = Sys.time(),
            ip = '127.0.0.1',
            agent = 'Mozilla/5.0')
    write.table(
        visitor,
        file = file.path(www, 'counter.tsv'),
        quote = FALSE,
        sep = "\t",
        row.names = FALSE
    )
    # Write the app.R
    writeLines(c(
        "library(scRNAseqApp)",
        paste0("scRNAseqApp('", datafolder, "')")
    ),
    file.path(app_path, "app.R"))
    return(invisible())
}