#' Run the core model
#'
#' @param obj An object of class \code{BTFr} from \code{\link{run_modern}}
#' @param core_species Dataframe containing core species counts
#' @param prior_el prior elevations if available
#' @param ChainNums The number of MCMC chains
#' @param n.iter The number of MCMC iterations
#' @param n.burnin The number of burnin MCMC samples
#' @param n.thin The number of thinning
#' @param validation.run Set to TRUE if running validation
#' @param use_uniform_prior change prior on elevation to be uniform
#' @param parallel Logical. Whether to run MCMC chains in parallel. Default is TRUE
#' @param n_cores Number of CPU cores to use for parallel processing. If NULL, uses all available cores minus 1
#'
#' @return a list of objects including SWLI and an mcmc array with posterior samples
#' @export
#' @import R2jags rjags
#' @importFrom dplyr "select" "ends_with"
#' @importFrom tidyr "pivot_longer"
#' @importFrom parallel "detectCores" "mclapply" "parLapply" "makeCluster" "stopCluster"
#' @examples
#' \donttest{
#' test_modern_mod <- run_modern(
#'   modern_elevation = NJ_modern_elevation,
#'   modern_species = NJ_modern_species,
#'   n.iter = 10,
#'   n.burnin = 1,
#'   n.thin = 1,
#'   parallel = FALSE
#' )
#' # Run with parallel processing disabled for examples
#' test_core_mod <- run_core(test_modern_mod,
#'   core_species = NJ_core_species,
#'   n.iter = 10,
#'   n.burnin = 1,
#'   n.thin = 1,
#'   parallel = FALSE
#' )
#'
#' # Run with parallel processing enabled (1 core for safety)
#' test_core_mod_par <- run_core(test_modern_mod,
#'   core_species = NJ_core_species,
#'   n.iter = 10,
#'   n.burnin = 1,
#'   n.thin = 1,
#'   parallel = TRUE,
#'   n_cores = 1
#' )
#' }
run_core <- function(obj,
                     core_species = NULL,
                     prior_el = NULL,
                     ChainNums = seq(1, 3),
                     n.iter = 15000,
                     n.burnin = 1000,
                     n.thin = 7,
                     validation.run = FALSE,
                     use_uniform_prior = FALSE,
                     parallel = TRUE,
                     n_cores = NULL) {
  # read in the core data
  if (!is.null(core_species)) {
    core_dat <- core_species
  } else {
    core_dat <- BTFr::NJ_core_species
  }


  if (!validation.run) {
    depth <- core_dat %>% dplyr::pull(Depth)
    core_data_sorted <- sort_core(
      core_dat = select(core_dat, -"Depth"),
      species_names = obj$species_names
    )
  }

  if (validation.run) {
    depth <- 1:nrow(core_dat)
    core_data_sorted <- sort_core(
      core_dat = core_dat,
      species_names = obj$species_names
    )
  }

  # Check if data includes priors
  if (!is.null(prior_el)) {
    use.informative.priors <- TRUE
    if (obj$scale_x) {
      prior_lwr <- (prior_el$prior_lwr - obj$x_center) / obj$x_scale
      prior_upr <- (prior_el$prior_upr - obj$x_center) / obj$x_scale
    }
    if (!obj$scale_x) {
      prior_lwr <- prior_el$prior_lwr / 100
      prior_upr <- prior_el$prior_upr / 100
    }


    prior_emin <- pmax(obj$elevation_min, prior_lwr)
    prior_emax <- pmin(obj$elevation_max, prior_upr)
    cat("Running with informative priors")
  }

  # Get other relevant info for the model
  y0 <- core_data_sorted$coredata_sorted

  begin0 <- obj$data$begin0
  el_mean <- mean(obj$data$x)
  N_count0 <- apply(y0, 1, sum)
  n0 <- nrow(y0)
  m0 <- ncol(y0)

  if (is.null(prior_el)) {
    emin <- rep(obj$elevation_min, n0)
    emax <- rep(obj$elevation_max, n0)
  }

  if (!is.null(prior_el)) {
    emin <- prior_emin
    emax <- prior_emax
  }


  ######### For Splines
  # This creates the components for the basis function matrix
  xl <- obj$elevation_min
  xr <- obj$elevation_max
  deg <- 3
  dx <- obj$dx
  knots <- seq(xl - deg * dx, xr + deg * dx, by = dx)
  n_knots <- length(knots)
  D <- diff(diag(n_knots), diff = deg + 1) / (gamma(deg + 1) * dx^deg)
  K <- dim(D)[1]
  Dmat <- 1
  Delta.hk <- diff(diag(K), diff = Dmat) # difference matrix
  Deltacomb.kh <- t(Delta.hk) %*% solve(Delta.hk %*% t(Delta.hk))

  # Jags model data
  pars <- c("p", "x0")

  data <- list(
    y = y0,
    n = n0,
    m = m0,
    N_count = N_count0,
    D = D,
    Deltacomb.kh = Deltacomb.kh,
    knots = knots,
    deg = deg,
    n_knots = n_knots,
    begin0 = begin0,
    beta0.j = obj$beta0.j,
    beta0_sd = obj$beta0_sd,
    delta0.hj = obj$delta0.hj,
    delta0_sd = obj$delta0_sd,
    tau.z0 = obj$tau.z0,
    emin = emin,
    emax = emax,
    el_mean = el_mean,
    use_uniform_prior = use_uniform_prior,
    x_center = obj$x_center,
    x_scale = obj$x_scale
  )

  temp_files <- rep(NA, length(ChainNums))

  if (parallel && length(ChainNums) > 1) {
    # Determine number of cores to use
    if (is.null(n_cores)) {
      n_cores <- max(1, parallel::detectCores() - 1)
    }
    n_cores <- min(n_cores, length(ChainNums))

    cat(paste("Running", length(ChainNums), "chains in parallel using", n_cores, "cores"), "\n")

    # Create a function for parallel execution
    run_chain_parallel <- function(chainNum) {
      cat(paste("Start chain ID ", chainNum), "\n")
      run <- InternalRunCore(
        chainNum = chainNum,
        jags_data = data,
        jags_pars = pars,
        n.burnin = n.burnin,
        n.iter = n.iter,
        n.thin = n.thin
      )
      return(list(chainNum = chainNum, file = run$file))
    }

    # Run chains in parallel based on platform
    if (.Platform$OS.type == "unix") {
      # Unix-like systems (Linux, macOS)
      results <- parallel::mclapply(ChainNums, run_chain_parallel, mc.cores = n_cores)
    } else {
      # Windows
      cl <- parallel::makeCluster(n_cores)
      # Export necessary objects to cluster
      parallel::clusterExport(cl, c(
        "InternalRunCore", "data", "pars", "n.burnin",
        "n.iter", "n.thin"
      ), envir = environment())
      # Load required packages on cluster nodes
      parallel::clusterEvalQ(cl, {
        requireNamespace("R2jags", quietly = TRUE)
        requireNamespace("rjags", quietly = TRUE)
      })
      results <- parallel::parLapply(cl, ChainNums, run_chain_parallel)
      parallel::stopCluster(cl)
    }

    # Extract results
    for (result in results) {
      temp_files[result$chainNum] <- result$file
    }
  } else {
    # Sequential execution (original behavior)
    for (chainNum in ChainNums) {
      cat(paste("Start chain ID ", chainNum), "\n")

      run <- InternalRunCore(
        chainNum = chainNum,
        jags_data = data,
        jags_pars = pars,
        n.burnin = n.burnin,
        n.iter = n.iter,
        n.thin = n.thin
      )
      temp_files[chainNum] <- run$file
    }
  }

  data[["depth"]] <- depth
  # Store MCMC output in an array
  get_core_out <- internal_get_core_output(
    ChainNums = ChainNums,
    jags_data = data,
    scale_x = obj$scale_x,
    temp_files = temp_files
  )
  core_out <- list(
    SWLI = get_core_out$SWLI,
    mcmc.array = get_core_out$x0.samps
  )

  class(core_out) <- "BTFr"

  invisible(core_out)
}

#-----------------------------------------------------
InternalRunCore <- function(
    # Do MCMC sampling
    ### Do MCMC sampling for one chain
    chainNum, ## << Chain ID
    jags_data,
    jags_pars,
    n.burnin,
    n.iter,
    n.thin) {
  # set seed before sampling the initial values
  set.seed.chain <- chainNum * 209846
  jags.dir <- tempdir()
  set.seed(set.seed.chain)
  temp <- stats::rnorm(1)

  # The model for the modern data
  model_file <- tempfile("model.txt")
  cat("
#--------------------------------------------------------------
# Model for BTF
#--------------------------------------------------------------

model{", sep = "", append = FALSE, file = model_file, fill = TRUE)

  cat("
  for(i in 1:n)
  {

  # Set up for basis functions where x0 needs to be estimated
  for(k in 1:n_knots)
  {
  J[i,k]<-step(x0[i]-knots[k])
  L[i,k]<-((x0[i]-knots[k])^deg)*J[i,k]
  }

  for(j in begin0:m){
  lambda[i,j] <- 1
  }
  for(j in 1:(begin0-1)){
  spline[i,j] <- beta0.j[j] + inprod(Z0.ih[i,],delta0.hj[,j])

  ##Account for over/under dispersion
  z[i,j] ~ dnorm(spline[i,j],tau.z0[j])
  lambda[i,j]<-exp(z[i,j])
  }#End j loop

  y[i,]~dmulti(p[i,],N_count[i])
  lambdaplus[i]<-sum(lambda[i,])

  for(j in 1:m){
  p[i,j]<-lambda[i,j]/lambdaplus[i]
  }#End j loop
  }#End i loop

  #Get basis functions
  B0.ik <- pow(-1,(deg + 1)) * (L %*% t(D))
  Z0.ih <- B0.ik%*%Deltacomb.kh

  ", sep = "", append = TRUE, file = model_file, fill = TRUE)

  if (jags_data$use_uniform_prior == TRUE) {
    cat("
    for(i in 1:n)
    {
    #Prior for x0
    x0[i]~dunif(emin[i],emax[i])
    }
    ", sep = "", append = TRUE, file = model_file, fill = TRUE)
  }

  if (jags_data$use_uniform_prior == FALSE) {
    cat(
      "
    for(i in 1:n)
    {
    #Prior for x0
      x0[i]~dnorm(x0.mean[i],sd.x0[i]^-2)
      x0.mean[i]~dt(el_mean,1,1)T(emin[i],emax[i])
      sd.x0[i] <- 0.1
    }
    ",
      sep = "", append = TRUE, file = model_file, fill = TRUE
    )
  }

  cat("}",
    sep = "", append = TRUE, file = model_file, fill = TRUE
  )

  mod <- suppressWarnings(jags(
    data = jags_data,
    parameters.to.save = jags_pars,
    model.file = model_file,
    n.chains = 1,
    n.iter = n.iter,
    n.burnin = n.burnin,
    n.thin = n.thin,
    DIC = FALSE,
    jags.seed = set.seed.chain
  ))

  mod_upd <- mod
  temp.jags.file <- tempfile(paste0("jags_mod", chainNum), jags.dir, ".Rdata")
  save(mod_upd, file = temp.jags.file)

  cat(paste("Hooraah, Chain", chainNum, "has finished!"), "\n")

  return(list(file = temp.jags.file))
}

internal_get_core_output <- function(ChainNums, jags_data, scale_x = FALSE, temp_files) {
  mcmc.array <- ConstructMCMCArray(
    ChainIDs = ChainNums,
    temp_files = temp_files
  )
  n <- jags_data$n

  pars.check <- rep(NA, n)
  for (i in 1:n) {
    pars.check[i] <- paste0("x0[", i, "]")
  }


  # Get gelman diagnostics (Rhat threshold = 1.1)
  # If gelman diagnostic fails then stop!
  gd <- BTFr::gr_diag(mcmc.array, pars.check = pars.check)
  if (gd == -1) {
    cat("WARNING! Convergence issues, check trace plots \n")
  }
  # If gelman diagnostic passes then get other diagnostics
  if (gd == 0) {
    BTFr::eff_size(mcmc.array, pars.check = pars.check)
    BTFr::mcse(mcmc.array, pars.check = pars.check)
  }

  n_samps <- dim(mcmc.array)[1]

  # Get the sorted core data
  Depth <- jags_data$depth
  x0.samps <- array(NA, c(n_samps, n))

  if (scale_x) {
    for (i in 1:n)
    {
      parname <- paste0("x0[", i, "]")
      x0.samps[, i] <- (mcmc.array[1:n_samps, sample(ChainNums, 1), parname] * jags_data$x_scale) + jags_data$x_center
    }
  }

  if (!scale_x) {
    for (i in 1:n)
    {
      parname <- paste0("x0[", i, "]")
      x0.samps[, i] <- mcmc.array[1:n_samps, sample(ChainNums, 1), parname] * 100
    }
  }

  SWLI <- apply(x0.samps, 2, mean)
  SWLI_SD <- apply(x0.samps, 2, stats::sd)
  lower <- SWLI - 2 * SWLI_SD
  upper <- SWLI + 2 * SWLI_SD

  sigma <- (upper - lower) / 4
  SWLI_data <- cbind(Depth, SWLI, sigma, lower, upper)

  return(list(SWLI = SWLI_data, x0.samps = x0.samps))
}
