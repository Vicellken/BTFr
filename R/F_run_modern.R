#-----------------------------------------------------
#' Run the modern (calibration) model
#'
#' @param modern_elevation A dataframe of modern elevations
#' @param modern_species A dataframe of modern counts (to be sorted with \code{\link{sort_modern}})
#' @param scale_x Set to TRUE to scale elevation data to have mean 0 and sd 1
#' @param sigma_z_priors priors for foram variability (if available)
#' @param dx The elevation interval for spacing the spline knots. Defaults to 0.2
#' @param ChainNums The number of MCMC chains to run
#' @param n.iter The number of iterations
#' @param n.burnin The number of burnin samples
#' @param n.thin The number of thinning
#' @param validation.run Defaults to FALSE. Set to TRUE if running a validation
#' @param fold Fold number for cross validation (CV)
#' @param parallel Logical. Whether to run MCMC chains in parallel. Default is TRUE
#' @param n_cores Number of CPU cores to use for parallel processing. If NULL, uses all available cores minus 1
#'
#' @return a list of objects including data, parameter values and scaling information
#' @export
#' @importFrom parallel "detectCores" "mclapply" "parLapply" "makeCluster" "stopCluster"
#'
#' @examples
#' \donttest{
#' # Run with parallel processing disabled for examples
#' test_modern_mod <- run_modern(
#'   modern_elevation = NJ_modern_elevation,
#'   modern_species = NJ_modern_species,
#'   n.iter = 10,
#'   n.burnin = 1,
#'   n.thin = 1,
#'   parallel = FALSE
#' )
#'
#' # Run with parallel processing enabled (1 core for safety)
#' test_modern_mod_par <- run_modern(
#'   modern_elevation = NJ_modern_elevation,
#'   modern_species = NJ_modern_species,
#'   n.iter = 10,
#'   n.burnin = 1,
#'   n.thin = 1,
#'   parallel = TRUE,
#'   n_cores = 1
#' )
#' }
#'
run_modern <- function(modern_elevation = NULL,
                       modern_species = NULL,
                       scale_x = FALSE,
                       sigma_z_priors = NULL,
                       dx = 0.1,
                       ChainNums = seq(1, 3),
                       n.iter = 40000,
                       n.burnin = 10000,
                       n.thin = 15,
                       validation.run = FALSE,
                       fold = 1,
                       parallel = TRUE,
                       n_cores = NULL) {
  # read in the modern data
  if (!is.null(modern_species)) {
    modern_dat <- modern_species
  } else {
    modern_dat <- BTFr::NJ_modern_species
  }

  # get the sorted (by species counts) modern data
  modern_data_sorted <- sort_modern(modern_dat)
  species_names <- modern_data_sorted$species_names

  # read in the elevation data
  if (!is.null(modern_elevation)) {
    elevation_dat <- modern_elevation
  } else {
    elevation_dat <- BTFr::NJ_modern_elevation
  }

  # apply scaling if specified
  if (scale_x) {
    modern_elevation <- scale(elevation_dat$SWLI)
    scale_att <- attributes(modern_elevation)
  }

  if (!scale_x) {
    modern_elevation <- as.matrix(elevation_dat$SWLI / 100)
    scale_att <- NULL
  }

  # run validation if specified
  if (validation.run) {
    set.seed(3847)
    K <- 10
    folds <- rep(1:K, ceiling(nrow(modern_data_sorted$moderndat_sorted) / K))
    folds <- folds[sample(1:length(modern_elevation))]
    test_samps <- which(folds == fold)
    test_samps

    y <- modern_data_sorted$moderndat_sorted[-test_samps, ]
    x <- modern_elevation[-test_samps, 1]
    y_test <- tibble::as_tibble(modern_data_sorted$moderndat_sorted[test_samps, ])
    x_test <- tibble::as_tibble(modern_elevation[test_samps, 1])
  }

  if (!validation.run) {
    y <- modern_data_sorted$moderndat_sorted
    x <- modern_elevation[, 1]
    y_test <- NULL
    x_test <- NULL
  }

  # Get min/max elevations (will be used with priors)
  elevation_min <- floor(min(modern_elevation))
  elevation_max <- ceiling(max(modern_elevation))

  # Get index for the first species (if any) that has all zero counts
  begin0 <- modern_data_sorted$begin0

  # Total species counts
  N_count <- apply(y, 1, sum)

  # Regular B Splines Create some basis functions
  res <- bbase(x, xl = elevation_min, xr = elevation_max, dx = dx) # This creates the basis function matrix
  B.ik <- res$B.ik
  K <- dim(B.ik)[2]

  D <- 1
  Delta.hk <- diff(diag(K), diff = D)
  Deltacomb.kh <- t(Delta.hk) %*% solve(Delta.hk %*% t(Delta.hk))
  Z.ih <- B.ik %*% Deltacomb.kh
  H <- dim(Z.ih)[2]

  # Prior specifications
  if (is.null(sigma_z_priors)) {
    mean_sigma_z <- rep(0, ncol(y))
    sd_sigma_z <- rep(1, ncol(y))
  }

  if (!is.null(sigma_z_priors)) {
    species_prior <- sigma_z_priors$species
    mean_sigma_z <- rep(0, ncol(y))
    sd_sigma_z <- rep(2, ncol(y))

    match_index <- match(species_names, species_prior)[1:length(species_prior)]

    mean_sigma_z[1:length(species_prior)] <- sigma_z_priors$mean_sigma_overall[match_index]
    sd_sigma_z[1:length(species_prior)] <- sigma_z_priors$sd_sigma_overall[match_index]
  }


  # Jags model data
  pars <- c("p", "beta.j", "sigma.z", "sigma.delta", "delta.hj", "spline")

  data <- list(
    y = y,
    n = nrow(y),
    m = ncol(y),
    N_count = N_count,
    H = H,
    Z.ih = Z.ih,
    begin0 = begin0,
    mean_sigma_z = mean_sigma_z,
    sd_sigma_z = sd_sigma_z
  )

  # run the model
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
      run <- InternalRunOneChain(
        chainNum = chainNum, jags_data = data,
        jags_pars = pars, n.burnin = n.burnin, n.iter = n.iter,
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
        "InternalRunOneChain", "data", "pars", "n.burnin",
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

      run <- InternalRunOneChain(
        chainNum = chainNum, jags_data = data,
        jags_pars = pars, n.burnin = n.burnin, n.iter = n.iter,
        n.thin = n.thin
      )

      temp_files[chainNum] <- run$file
    }
  }

  # Get model output needed for the core run
  data[["x"]] <- x
  data[["y_test"]] <- y_test
  data[["x_test"]] <- x_test

  jags_data <- list(
    data = data,
    pars = pars,
    elevation_max = elevation_max,
    elevation_min = elevation_min,
    dx = dx,
    species_names = species_names,
    x_center = scale_att$`scaled:center`,
    x_scale = scale_att$`scaled:scale`,
    temp_files = temp_files
  )

  # create the core input
  core_input <- internal_get_core_input(
    ChainNums = ChainNums,
    jags_data = jags_data,
    scale_x = scale_x
  )

  # Update jags_data list
  modern_out <- list(
    data = data,
    pars = pars,
    elevation_max = elevation_max,
    elevation_min = elevation_min,
    dx = dx,
    species_names = species_names,
    delta0.hj = core_input$delta0.hj,
    delta0_sd = core_input$delta0_sd,
    beta0.j = core_input$beta0.j,
    beta0_sd = core_input$beta0_sd,
    sig0_z = core_input$sig0_z,
    tau.z0 = core_input$tau.z0,
    src_dat = core_input$src_dat,
    scale_x = scale_x,
    x_center = scale_att$`scaled:center`,
    x_scale = scale_att$`scaled:scale`
  )

  class(modern_out) <- "BTFr"

  invisible(modern_out)
}

#-----------------------------------------------------
InternalRunOneChain <- function(chainNum, jags_data, jags_pars, n.burnin,
                                n.iter, n.thin) {
  set.seed.chain <- chainNum * 209846
  jags.dir <- tempdir()
  set.seed(set.seed.chain)
  temp <- stats::rnorm(1)

  # The model for the modern data
  modernmodel <- "
  model
  {

  for(i in 1:n)
  {
  for(j in begin0:m){
  lambda[i,j] <- 1
  }
  for(j in 1:(begin0-1)){
  spline[i,j] <- beta.j[j] + inprod(Z.ih[i,],delta.hj[,j])
  z[i,j] ~ dnorm(spline[i,j],tau.z[j])
  lambda[i,j] <- exp(z[i,j])
  }#End j loop

  y[i,] ~ dmulti(p[i,],N_count[i])
  lambdaplus[i] <- sum(lambda[i,])
  }#End i loop

  ###Get p's for multinomial
  for(i in 1:n){
  for(j in 1:m){
  p[i,j] <- lambda[i,j]/lambdaplus[i]
  }#End j loop
  }#End i loop


  #####Spline parameters#####
  #Coefficients
  for(j in 1:(begin0-1)){
  for (h in 1:H)
  {
  delta.hj[h,j] ~ dnorm(0, tau.delta)
  }
  }
  #Smoothness
  tau.delta<-pow(sigma.delta,-2)
  sigma.delta~dt(0, 2^-2, 1)T(0,)
  ###Variance parameter###
  for(j in 1:(begin0-1)){
  tau.z[j] <- pow(sigma.z[j],-2)
  sigma.z[j] ~ dt(mean_sigma_z[j], sd_sigma_z[j]^-2, 1)T(0,)
  ###Intercept (species specific)
  beta.j[j] ~ dt(0,100^-2,1)
  }

  }##End model
  "

  mod <- jags(
    data = jags_data, parameters.to.save = jags_pars, model.file = textConnection(modernmodel),
    n.chains = 1, n.iter = n.iter, n.burnin = n.burnin, n.thin = n.thin,
    DIC = FALSE, jags.seed = set.seed.chain
  )

  mod_upd <- mod
  temp.jags.file <- tempfile(paste0("jags_mod", chainNum), jags.dir, ".Rdata")
  save(mod_upd, file = temp.jags.file)

  cat(paste("Hooraah, Chain", chainNum, "has finished!"), "\n")

  return(list(file = temp.jags.file))
}

#-----------------------------------------------------
internal_get_core_input <- function(ChainNums, jags_data, scale_x = FALSE) {
  mcmc.array <- ConstructMCMCArray(
    ChainIDs = ChainNums,
    temp_files = jags_data$temp_files
  )

  n_samps <- dim(mcmc.array)[1]

  ######### For Splines #########
  # This creates the components for the basis function matrix
  xl <- jags_data$elevation_min
  xr <- jags_data$elevation_max
  begin0 <- jags_data$data$begin0
  deg <- 3
  dx <- jags_data$dx
  knots <- seq(xl - deg * dx, xr + deg * dx, by = dx)
  n_knots <- length(knots)
  D <- diff(diag(n_knots), diff = deg + 1) / (gamma(deg + 1) * dx^deg)
  K <- dim(D)[1]
  Dmat <- 1
  Delta.hk <- diff(diag(K), diff = Dmat) # difference matrix
  Deltacomb.kh <- t(Delta.hk) %*% solve(Delta.hk %*% t(Delta.hk))

  ########## Get parameter estimates ##########

  # Data
  y <- jags_data$data$y
  n <- nrow(y)
  m <- ncol(y)
  x <- jags_data$data$x
  species_names <- jags_data$species_names

  # Parameters
  delta.hj_samps <- array(NA, c(n_samps, jags_data$data$H, (begin0 - 1)))
  beta.j_samps <- sigma.z_samps <- array(NA, c(n_samps, (begin0 - 1)))

  for (j in 1:(begin0 - 1))
  {
    for (h in 1:jags_data$data$H)
    {
      parname <- paste0("delta.hj[", h, ",", j, "]")
      delta.hj_samps[, h, j] <- mcmc.array[1:n_samps, sample(ChainNums, 1), parname]
    }
    parname <- paste0("beta.j[", j, "]")
    beta.j_samps[, j] <- mcmc.array[1:n_samps, sample(ChainNums, 1), parname]
  }

  for (j in 1:(begin0 - 1))
  {
    parname <- paste0("sigma.z[", j, "]")
    sigma.z_samps[, j] <- mcmc.array[1:n_samps, sample(ChainNums, 1), parname]
  }

  delta0.hj <- apply(delta.hj_samps, 2:3, mean)
  delta0_sd <- apply((apply(delta.hj_samps, 2:3, stats::sd)), 2, stats::median)

  beta0.j <- apply(beta.j_samps, 2, mean)
  beta0_sd <- apply(beta.j_samps, 2, stats::sd) %>% stats::median()

  sig0_z <- apply(sigma.z_samps, 2, mean)

  sigma.z0 <- rep(NA, (begin0 - 1))
  for (i in 1:(begin0 - 1))
  {
    sigma.z0[i] <- delta0_sd[i] + sig0_z[i]
  }
  tau.z0 <- 1 / (sigma.z0^2)

  # SRCs
  p_star <- p_star_all <- spline_star <- z_star <- spline_star_all <- array(
    NA,
    c(n_samps, length(x), m)
  )

  for (i in 1:n_samps) {
    for (j in begin0:m) {
      spline_star_all[i, , j] <- 0
    }
    for (j in 1:(begin0 - 1)) {
      for (k in 1:length(x)) x.index <- seq(1:length(x))
      spline_star_all[i, , j] <- exp(mcmc.array[i, sample(ChainNums, 1), paste0("spline[", x.index, ",", j, "]")])
    }
  }


  for (i in 1:n_samps) {
    for (j in 1:m) {
      p_star_all[i, , j] <- spline_star_all[i, , j] / apply(spline_star_all[i, , ], 1, sum)
    }
  }


  # Get predicted values
  pred_pi_mean <- apply(p_star_all, 2:3, mean)
  pred_pi_high <- apply(p_star_all, 2:3, "quantile", 0.975)
  pred_pi_low <- apply(p_star_all, 2:3, "quantile", 0.025)


  if (scale_x) {
    df <- data.frame((x * jags_data$x_scale) + jags_data$x_center, pred_pi_mean)
    df_low <- data.frame((x * jags_data$x_scale) + jags_data$x_center, pred_pi_low)
    df_high <- data.frame((x * jags_data$x_scale) + jags_data$x_center, pred_pi_high)
  }

  if (!scale_x) {
    df <- data.frame(x * 100, pred_pi_mean)
    df_low <- data.frame(x * 100, pred_pi_low)
    df_high <- data.frame(x * 100, pred_pi_high)
  }

  colnames(df) <- c("SWLI", species_names)
  colnames(df_low) <- c("SWLI", species_names)
  colnames(df_high) <- c("SWLI", species_names)


  df_long <- df %>% tidyr::pivot_longer(
    names_to = "species", values_to = "proportion",
    -SWLI
  )
  df_low_long <- df_low %>% tidyr::pivot_longer(
    names_to = "species", values_to = "proportion_lwr",
    -SWLI
  )
  df_high_long <- df_high %>% tidyr::pivot_longer(
    names_to = "species", values_to = "proportion_upr",
    -SWLI
  )

  src_dat <- df_long %>%
    dplyr::mutate(proportion_lwr = df_low_long %>%
      dplyr::pull(proportion_lwr), proportion_upr = df_high_long %>%
      dplyr::pull(proportion_upr)) %>%
    dplyr::arrange(SWLI)


  return(list(
    delta0.hj = delta0.hj,
    delta0_sd = delta0_sd,
    beta0.j = beta0.j,
    beta0_sd = beta0_sd,
    sig0_z = sig0_z,
    tau.z0 = tau.z0,
    src_dat = src_dat
  ))
}
