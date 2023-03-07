#' Generate data files required for shiny app
#'
#' Copied from ShinyCell to generate the data files.
#' @noRd
#' @param obj input single-cell object for Seurat (v3+)
#' @param scConf config data.table
#' @param assayName assay in single-cell data object to use for plotting
#'   gene expression, which must match one of the following:
#'   \itemize{
#'     \item{Seurat objects}: "RNA" or "integrated" assay,
#'       default is "RNA"
#'   }
#' @param gexSlot slot in single-cell gex assay to plot.
#' Default is to use the "data" slot
#' @param atacAssayName assay in single-cell data object to use for plotting
#' open chromatin.
#' @param atacSlot slot in single-cell atac assay to plot.
#' Default is to use the "data" slot
#' @param appDir specify directory to create the shiny app in
#' @param defaultGene1 specify primary default gene to show
#' @param defaultGene2 specify secondary default gene to show
#' @param default.multigene character vector specifying default genes to
#'   show in bubbleplot / heatmap
#' @param default.dimred character vector specifying the two default dimension
#'   reductions. Default is to use UMAP if not TSNE embeddings
#' @param chunkSize number of genes written to h5file at any one time. Lower
#'   this number to reduce memory consumption. Should not be less than 10
#'
#' @return data files required for shiny app
#' @importFrom SeuratObject GetAssayData VariableFeatures Embeddings Reductions
#' @importFrom data.table data.table as.data.table
#' @importFrom hdf5r H5File h5types H5S
#' @importFrom Rsamtools TabixFile seqnamesTabix scanTabix
#' @importFrom GenomeInfoDb keepSeqlevels seqinfo seqnames
#' @importFrom GenomicRanges GRanges width
#' @importFrom rtracklayer export
#' @importFrom utils read.table
makeShinyFiles <- function(
        obj,
        scConf,
        assayName,
        gexSlot = c("data", "scale.data", "counts"),
        atacAssayName,
        atacSlot = c("data", "scale.data", "counts"),
        appDir = "data",
        defaultGene1 = NA,
        defaultGene2 = NA,
        default.multigene = NA,
        default.dimred = NA,
        chunkSize = 500) {
    ### Preprocessing and checks
    # Generate defaults for assayName / slot
    stopifnot(is(obj[1], "Seurat"))
    # Seurat Object
    if (missing(assayName)) {
        assayName <- "RNA"
    } else{
        assayName <- assayName[1]
    }
    gexSlot <- match.arg(gexSlot)
    atacSlot <- match.arg(atacSlot)
    gexAsy <- GetAssayData(obj, assay = assayName, slot = gexSlot)
    gex.matdim <- dim(gexAsy)
    gex.rownm <- rownames(gexAsy)
    gex.colnm <- colnames(gexAsy)
    defGenes <- VariableFeatures(obj)[seq.int(10)]
    if (is.na(defGenes[1])) {
        warning(
            "Variable genes for seurat object not found! Have you ",
            "ran `FindVariableFeatures` or `SCTransform`?"
        )
        defGenes <- gex.rownm[seq.int(10)]
    }
    sc1meta <- data.table(sampleID = rownames(obj[[]]), obj[[]])
    
    geneMap <- gex.rownm
    names(geneMap) <- gex.rownm    # Basically no mapping
    
    defGenes <- geneMap[defGenes]
    
    # Check defaultGene1 / defaultGene2 / default.multigene
    defaultGene1 <- defaultGene1[1]
    defaultGene2 <- defaultGene2[1]
    if (is.na(defaultGene1)) {
        defaultGene1 <- defGenes[1]
    }
    if (is.na(defaultGene2)) {
        defaultGene2 <- defGenes[2]
    }
    if (is.na(default.multigene[1])) {
        default.multigene <- defGenes
    }
    if (defaultGene1 %in% geneMap) {
        defaultGene1 <- defaultGene1
    } else {
        warning(
            "defaultGene1 doesn't exist in gene expression, using defaults...")
        defaultGene1 <- defGenes[1]
    }
    if (defaultGene2 %in% geneMap) {
        defaultGene2 <- defaultGene2
    } else {
        warning(
            "defaultGene2 doesn't exist in gene expression, using defaults...")
        defaultGene2 <- defGenes[2]
    }
    if (all(default.multigene %in% geneMap)) {
        default.multigene <- default.multigene
    } else {
        warning(
            "default.multigene doesn't exist in gene expression, ",
            "using defaults...")
        default.multigene <- defGenes
    }
    
    # save data
    sc1conf <- scConf
    sc1conf$dimred <- FALSE
    sc1meta <-
        sc1meta[, c("sampleID", as.character(sc1conf$ID)), with = FALSE]
    # Factor metadata again
    for (i in as.character(sc1conf[!is.na(sc1conf$fID)]$ID)) {
        sc1meta[[i]] <- factor(
            sc1meta[[i]],
            levels =
                strsplit(sc1conf[sc1conf$ID == i]$fID, "\\|")[[1]])
        levels(sc1meta[[i]]) <-
            strsplit(sc1conf[sc1conf$ID == i]$fUI, "\\|")[[1]]
        sc1conf[sc1conf$ID == i]$fID <- sc1conf[sc1conf$ID == i]$fUI
    }
    # Extract dimred and append to both XXXmeta.rds and XXXconf.rds...
    for (iDR in Reductions(obj)) {
        drMat <- Embeddings(obj[[iDR]])
        if (ncol(drMat) > 5) {
            drMat <- drMat[, seq.int(5)]
        }  # Take first 5 components only
        drMat <- drMat[sc1meta$sampleID,]          # Ensure ordering
        drMat <- as.data.table(drMat)
        sc1meta <- cbind(sc1meta, drMat)
        
        # Update sc1conf accordingly
        tmp <- data.table(
            ID = colnames(drMat),
            UI = colnames(drMat),
            fID = NA,
            fUI = NA,
            fCL = NA,
            fRow = NA,
            default = 0,
            grp = FALSE,
            dimred = TRUE
        )
        tmp$UI <- gsub("_", "", tmp$UI)
        sc1conf <- rbindlist(list(sc1conf, tmp))
    }
    sc1conf$ID <- as.character(sc1conf$ID)     # Remove levels
    
    # Make XXXgexpr.h5
    if (!dir.exists(appDir)) {
        dir.create(appDir)
    }
    filename <- file.path(appDir, .globals$filenames$sc1gexpr)
    sc1gexpr <- H5File$new(filename, mode = "w")
    sc1gexpr.grp <- sc1gexpr$create_group("grp")
    sc1gexpr.grp.data <- sc1gexpr.grp$create_dataset(
        "data",
        dtype = h5types$H5T_NATIVE_FLOAT,
        space = H5S$new("simple", dims = gex.matdim, maxdims = gex.matdim),
        chunk_dims = c(1, gex.matdim[2])
    )
    chk <- chunkSize
    while (chk > (gex.matdim[1] - 8)) {
        chk <-
            floor(chk / 2)     # Account for cases where nGene < chunkSize
    }
    for (i in seq.int(floor((gex.matdim[1] - 8) / chk))) {
        sc1gexpr.grp.data[((i - 1) * chk + 1):(i * chk),] <-
            as.matrix(gexAsy[((i - 1) * chk + 1):(i * chk), ])
    }
    sc1gexpr.grp.data[(i * chk + 1):gex.matdim[1],] <-
        as.matrix(gexAsy[(i * chk + 1):gex.matdim[1], ])
    
    # sc1gexpr.grp.data[, ] <- as.matrix(gex.matrix[,])
    sc1gexpr$close_all()
    if (!isTRUE(all.equal(sc1meta$sampleID, gex.colnm))) {
        sc1meta$sampleID <- factor(sc1meta$sampleID, levels = gex.colnm)
        sc1meta <- sc1meta[order(sc1meta$sampleID)]
        sc1meta$sampleID <- as.character(sc1meta$sampleID)
    }
    
    # Make XXXgenes.rds
    sc1gene <- seq(gex.matdim[1])
    names(geneMap) <- NULL
    names(sc1gene) <- geneMap
    sc1gene <- sc1gene[order(names(sc1gene))]
    sc1gene <- sc1gene[order(nchar(names(sc1gene)))]
    
    # Make XXXdef.rds (list of defaults)
    if (all(default.dimred %in% sc1conf[sc1conf$dimred == TRUE]$ID)) {
        default.dimred[1] <- sc1conf[sc1conf$ID == default.dimred[1]]$UI
        default.dimred[2] <- sc1conf[sc1conf$ID == default.dimred[2]]$UI
    } else if (all(default.dimred %in% sc1conf[sc1conf$dimred == TRUE]$UI)) {
        default.dimred <- default.dimred    # Nothing happens
    } else {
        warn <- TRUE
        if (is.na(default.dimred[1])) {
            default.dimred <- "umap"
            warn <- FALSE
        }
        # Try to guess... and give a warning
        guess <- gsub("[0-9]", "", default.dimred[1])
        if (length(
            grep(
                guess, sc1conf[sc1conf$dimred == TRUE]$UI,
                ignore.case = TRUE)) >= 2) {
            default.dimred <-
                sc1conf[sc1conf$dimred == TRUE]$UI[
                    grep(
                        guess, sc1conf[sc1conf$dimred == TRUE]$UI,
                        ignore.case = TRUE)[c(1, 2)]]
        } else {
            nDR <- length(sc1conf[sc1conf$dimred == TRUE]$UI)
            default.dimred <-
                sc1conf[sc1conf$dimred == TRUE]$UI[(nDR - 1):nDR]
        }
        if (warn) {
            warning(
                "default.dimred not found, switching to ",
                default.dimred[1],
                " and ",
                default.dimred[1]
            )
        } # Warn if user-supplied default.dimred is not found
    }
    # Note that we stored the display name here
    sc1def <- list()
    sc1def$meta1 <-
        sc1conf[sc1conf$default == 1]$UI   # Use display name
    sc1def$meta2 <-
        sc1conf[sc1conf$default == 2]$UI   # Use display name
    sc1def$gene1 <- defaultGene1              # Actual == Display name
    sc1def$gene2 <- defaultGene2              # Actual == Display name
    sc1def$genes <-
        default.multigene          # Actual == Display name
    sc1def$dimred <- default.dimred            # Use display name
    tmp <- nrow(sc1conf[sc1conf$default != 0 & sc1conf$grp == TRUE])
    if (tmp == 2) {
        sc1def$grp1 <- sc1def$meta1
        sc1def$grp2 <- sc1def$meta2
    } else if (tmp == 1) {
        sc1def$grp1 <-
            sc1conf[sc1conf$default != 0 & sc1conf$grp == TRUE]$UI
        if (nrow(
            sc1conf[sc1conf$default == 0 & sc1conf$grp == TRUE]) == 0) {
            sc1def$grp2 <- sc1def$grp1
        } else {
            sc1def$grp2 <-
                sc1conf[sc1conf$default == 0 & sc1conf$grp == TRUE]$UI[1]
        }
    } else {
        sc1def$grp1 <-
            sc1conf[sc1conf$default == 0 & sc1conf$grp == TRUE]$UI[1]
        if (nrow(
            sc1conf[sc1conf$default == 0 & sc1conf$grp == TRUE]) < 2) {
            sc1def$grp2 <- sc1def$grp1
        } else {
            sc1def$grp2 <-
                sc1conf[sc1conf$default == 0 & sc1conf$grp == TRUE]$UI[2]
        }
    }
    sc1conf <- sc1conf[, -c("fUI", "default"), with = FALSE]
    
    ### Saving objects
    saveRDS(sc1conf, file = file.path(appDir, .globals$filenames$sc1conf))
    saveRDS(sc1meta, file = file.path(appDir, .globals$filenames$sc1meta))
    saveRDS(sc1gene, file = file.path(appDir, .globals$filenames$sc1gene))
    saveRDS(sc1def,  file = file.path(appDir, .globals$filenames$sc1def))
    
    ### save ATAC objects
    if (!missing(atacAssayName)) {
        if (atacAssayName %in% Assays(obj)) {
            rm(gexAsy)
            DefaultAssay(obj) <- atacAssayName
            ## links, the links between peaks and gene symbol,
            ## used to create the matrix table
            links <- GetAssayData(obj, slot = "links")
            ## annotations, used to plot gene model
            annotations <- GetAssayData(obj, slot = "annotation")
            if (length(links) < 1 || length(annotations) < 1) {
                stop("scATAC data are not available.")
            }
            ## get fragments for each cell and group
            fragments <- GetAssayData(obj, slot = "fragments")
            regions <- seqinfo(annotations)
            tryCatch({
                regions <- as(regions, "GRanges")
            }, error=function(.e){
                warning("Cannot get genomic informations")
            })
            grp <- sc1conf[sc1conf$grp, ]$ID
            if(is(regions, "GRanges")){
                message("The following steps will cost memories.")
                res <- list()
                for(k in seq_along(fragments)){
                    fragment.path <- fragments[[k]]@path
                    if(file.exists(fragment.path)){
                        tabix.file <- TabixFile(fragment.path)
                        open(con = tabix.file)
                        on.exit(close(tabix.file))
                        seqnames.in.both <- intersect(
                            x = seqnames(x = regions),
                            y = seqnamesTabix(file = tabix.file))
                        region <- keepSeqlevels(
                            x = regions,
                            value = seqnames.in.both,
                            pruning.mode = "coarse")
                        coverage <- lapply(seq_along(region), function(i){
                            reads <- scanTabix(
                                file = tabix.file,
                                param = regions[i])
                            reads <- read.table(text = reads[[1]])
                            colnames(reads) <- 
                                c("seqnames", "start", "end", "name", "score")
                            reads <- GRanges(reads)
                            reads.grp <- lapply(grp, function(.grp){
                                lapply(split(
                                    reads,
                                    sc1meta[[.grp]][
                                        match(reads$name, sc1meta$sampleID)]),
                                    function(.e){
                                        coverage(.e, weight = .e$score)
                                    })
                            })
                            rm(reads)
                            names(reads.grp) <- grp
                            reads.grp
                        })
                        names(coverage) <- as.character(seqnames(region))
                        ## coverage is 3 level list,
                        ## level 1, chromosome
                        ## level 2, group
                        ## level 3, factors in group
                        if(length(coverage)){
                            res[[k]] <- list()
                            for(i in names(coverage[[1]])){
                                res[[k]][[i]] <- list()
                                for(j in names(coverage[[1]][[1]])){
                                    res[[k]][[i]][[j]] <-
                                        Reduce(c, lapply(coverage,
                                                         function(.cvg){
                                            .cvg[[i]][[j]]
                                        }))
                                }
                            }
                        }
                        
                        close(tabix.file)
                        on.exit()
                    }
                }
                if(length(res)>0){
                    if(length(res)>1){
                        for(i in seq_along(res)[-1]){
                            res[[1]] <- lapply(res[[1]], function(.grp){
                                lapply(res[[1]][[.grp]], function(.fac){
                                    res[[1]][[.grp]][[.fac]] +
                                        res[[i]][[.grp]][[.fac]]
                                })
                            })
                        }
                    }
                    res <- lapply(res[[1]], function(.grp) {
                        lapply(.grp, function(.fac){
                            .fac <- GRanges(.fac)
                            .fac <- .fac[.fac$score!=0]
                            ## normalize by FPKM
                            .s <- .fac$score * width(.fac)/1e3
                            .fac$score <- 1e6*.fac$score/sum(.s)
                            .fac
                        })
                    })
                    mapply(res, names(res), FUN=function(.grp, .grpname){
                        mapply(.grp, names(.grp), FUN=function(.fac, .facname){
                            pf <- file.path(
                                appDir, .globals$filenames$bwspath, .grpname)
                            dir.create(pf,
                                recursive = TRUE, showWarnings=FALSE)
                            export(.fac, file.path(
                                pf,
                                paste0(.facname, ".bigwig")),
                                format = "BigWig")
                        })
                    })
                }
            }
            # asy used to create coverage files,
            # Note this is different from fragment signals
            # it just show the counts in each called peaks
            acAsy <- GetAssayData(obj, assay = atacAssayName, slot = atacSlot)
            acAsy <- acAsy[, sc1meta$sampleID]
            writeATACdata(acAsy, appDir)
            peaks <- do.call(rbind, strsplit(rownames(acAsy), "-"))
            peaks <- as.data.frame(peaks)
            colnames(peaks) <- c("seqnames", "start", "end")
            mode(peaks[, 2]) <- "numeric"
            mode(peaks[, 3]) <- "numeric"
            saveRDS(peaks, file = file.path(
                appDir, .globals$filenames$sc1peak
            ))
            saveRDS(links, file = file.path(
                appDir, .globals$filenames$sc1link
            ))
            saveRDS(annotations, file = file.path(
                appDir, .globals$filenames$sc1anno
            ))
        }
    }
    return(sc1conf)
}