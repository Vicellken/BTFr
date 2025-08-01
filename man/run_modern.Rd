% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/F_run_modern.R
\name{run_modern}
\alias{run_modern}
\title{Run the modern (calibration) model}
\usage{
run_modern(
  modern_elevation = NULL,
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
  n_cores = NULL
)
}
\arguments{
\item{modern_elevation}{A dataframe of modern elevations}

\item{modern_species}{A dataframe of modern counts (to be sorted with \code{\link{sort_modern}})}

\item{scale_x}{Set to TRUE to scale elevation data to have mean 0 and sd 1}

\item{sigma_z_priors}{priors for foram variability (if available)}

\item{dx}{The elevation interval for spacing the spline knots. Defaults to 0.2}

\item{ChainNums}{The number of MCMC chains to run}

\item{n.iter}{The number of iterations}

\item{n.burnin}{The number of burnin samples}

\item{n.thin}{The number of thinning}

\item{validation.run}{Defaults to FALSE. Set to TRUE if running a validation}

\item{fold}{Fold number for cross validation (CV)}

\item{parallel}{Logical. Whether to run MCMC chains in parallel. Default is TRUE}

\item{n_cores}{Number of CPU cores to use for parallel processing. If NULL, uses all available cores minus 1}
}
\value{
a list of objects including data, parameter values and scaling information
}
\description{
Run the modern (calibration) model
}
\examples{
\donttest{
# Run with parallel processing disabled for examples
test_modern_mod <- run_modern(
  modern_elevation = NJ_modern_elevation,
  modern_species = NJ_modern_species,
  n.iter = 10,
  n.burnin = 1,
  n.thin = 1,
  parallel = FALSE
)

# Run with parallel processing enabled (1 core for safety)
test_modern_mod_par <- run_modern(
  modern_elevation = NJ_modern_elevation,
  modern_species = NJ_modern_species,
  n.iter = 10,
  n.burnin = 1,
  n.thin = 1,
  parallel = TRUE,
  n_cores = 1
)
}

}
