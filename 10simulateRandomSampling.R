### libraries
library(biomaRt)
library(mlr)
library(foreach)
library(doParallel)

### options
set.seed(986, kind="L'Ecuyer-CMRG")
registerDoParallel(cores=detectCores())
ensembl <- useMart("ENSEMBL_MART_ENSEMBL", "hsapiens_gene_ensembl", host="mar2016.archive.ensembl.org")
chr <- c(1:22, "X", "Y", "MT")
type="protein_coding"

# read completeset
completeset <- readRDS("../data/completeset.rds")

# read pharmaprojects data for target information
pharmaprojects <- read.delim("../data/pipeline_triples.txt")
pharmaprojects <- subset(pharmaprojects,
                                GlobalStatus == "Clinical Trial" |
                                GlobalStatus == "Launched" |
                                GlobalStatus == "Phase I Clinical Trial" |
                                GlobalStatus == "Phase II Clinical Trial" |
                                GlobalStatus == "Phase III Clinical Trial" |
                                GlobalStatus == "Pre-registration" |
                                GlobalStatus == "Preclinical" |
                                GlobalStatus == "Registered")
pharmaprojects <- getBM(
                        attributes="ensembl_gene_id",
                        filters=c("entrezgene", "chromosome_name", "biotype"),
                        values=list(pharmaprojects$Target_EntrezGeneId, chr, type),
                        mart=ensembl)

# positive cases: these are targets according to targetpedia and/or pharmaprojects
positive <- unique(pharmaprojects)
positive <- completeset[completeset$ensembl_gene_id %in% positive$ensembl_gene_id, ]
positive$target <- 1

# tuned model
nn.mod <- readRDS("../data/nn.mod.rds")

# permutation test
n <- 10000
perm <- foreach (i = 1:n, .combine = rbind) %dopar% {
    
    # unknown cases: it's not known whether these are targets or not
    unknown <- completeset[!completeset$ensembl_gene_id %in% positive$ensembl_gene_id, ]
    unknown <- unknown[sample(nrow(unknown), nrow(positive)), ]
    unknown$target <- 0

    # dataset is made of positive and unknown cases
    # will be splitted into traing and test sets
    dataset <- rbind(positive, unknown)
    dataset$target <- as.factor(dataset$target)
    rownames(dataset) <- dataset$ensembl_gene_id
    dataset$ensembl_gene_id <- NULL

    ## task
    classif.task <- makeClassifTask(id="TargetPred", data=dataset, target="target", positive="1")
    # simply remove constatn features (if any)
    classif.task <- removeConstantFeatures(classif.task)

    ## number of features and observations
    nf <- getTaskNFeats(classif.task)
    no <- getTaskSize(classif.task)

    # training and test set
    train.set <- sample(no, size = round(0.8*no))
    test.set <- setdiff(seq(no), train.set)

    # neural network
    nn.lrn <- makeLearner("classif.nnet", MaxNWts = 5000, trace = FALSE, size = getTuneResult(nn.mod)$x$size, decay = getTuneResult(nn.mod)$x$decay)
    nn.lrn <- setPredictType(nn.lrn, predict.type="prob")
    nn.lrn <- setId(nn.lrn, "Neural Network")

    ## train model
    nn.mod <- train(nn.lrn, classif.task, subset=train.set)

    ## evaluate performance on test set
    nn.test.pred <- predict(nn.mod, task=classif.task, subset=test.set)
    nn.test.pred <- performance(nn.test.pred, measures=list(acc, auc))

}

# plot histograms
perm <- as.data.frame(perm)
png("../data/RandomSamplingACC.png", height=6*300, width=6*300, res=300)
print(
	  ggplot(perm, aes(acc)) +
		  geom_histogram(colour="black", fill="goldenrod1", bins=100) +
		  xlab("Accuracy") + 
		  ylab("Count") +
          xlim(0.6, 0.8) +
          theme_bw(24)
)
dev.off()
png("../data/RandomSamplingAUC.png", height=6*300, width=6*300, res=300)
print(
	  ggplot(perm, aes(auc)) +
		  geom_histogram(colour="black", fill="darkorange1", bins=100) +
		  xlab("AUC") + 
		  ylab("Count") +
          xlim(0.6, 0.9) +
          theme_bw(24)
)
dev.off()

# print stats
summary(perm$acc)
mean(perm$acc)
sd(perm$acc)
summary(perm$auc)
mean(perm$auc)
sd(perm$auc)
