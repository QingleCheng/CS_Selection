function [ targetSa ] = get_target_spectrum(knownPer, selectionParams, indPer, rup)
% Calculate and return the target mean spectrum, target and covariance
% matrix at available periods. Predicted spectral accelerations and
% corresponding standard deviations are computed using gmpeBSSA_2014 but
% can be replaced by a user-defined GMPE. If the GMPE is altered then the
% input arguments will likely also need to be adjusted
%
% INPUTS
%           knownPer        : available periods from the database
%           indPer          : period indicies of target response spectrum
%           eps_bar         : user input for epsilon (conditional
%                             selection)
% 
%           selectionParams : parameters controlling how the ground motion 
%                             selection is performed
%               .databaseFile : filename of the target database. This file should exist
%                               in the 'Databases' subfolder. Further documentation of
%                               these databases can be found at
%                               'Databases/WorkspaceDocumentation***.txt'.
%               .cond         : 0 to run unconditional selection
%                               1 to run conditional
%               .arb          : 1 for single-component selection and arbitrary component sigma
%                               2 for two-component selection and average component sigma
%               .RotD         : 50 to use SaRotD50 data
%                             : 100 to use SaRotD100 data
%               .isScaled     : =1 to allow records to be
%                               scaled, =0 otherwise
%               .maxScale     : The maximum allowable scale factor
%               .tol          : Tolerable percent error to skip optimization (only
%                               used for SSE optimization)
%               .optType      : =0 to use the sum of squared errors to
%                               optimize the selected spectra, =1 to use
%                               D-statistic calculations from the KS-test
%               .penalty      : >0 to penalize selected spectra more than
%                               3 sigma from the target at any period,
%                               =0 otherwise.
%               . weights     : [Weights for error in mean, standard deviation
%                               and skewness] e.g., [1.0,2.0 0.3]
%               .nLoop        : Number of loops of optimization to perform.
%               .nBig         : The number of spectra that will be searched
%               .indTcond     : Index of Tcond, the conditioning period
%               .recID        : Vector of index values for the selected
%                               spectra
%
%           rup             :  A structure with parameters that specify the rupture scenario
%                              for the purpose of evaluating a GMPE
%
%               .M_bar            : earthquake magnitude
%               .Rjb              : closest distance to surface projection of the fault rupture (km)
%               .Fault_Type       : =0 for unspecified fault
%                                   =1 for strike-slip fault
%                                   =2 for normal fault
%                                   =3 for reverse fault
%               .region           : =0 for global (incl. Taiwan)
%                                   =1 for California 
%                                   =2 for Japan 
%                                   =3 for China or Turkey 
%                                   =4 for Italy
%               .z1               : basin depth (km); depth from ground surface to the 1km/s shear-wave horizon, =999 if unknown
%               .Vs30             : average shear wave velocity in the top 30m of the soil (m/s)
%
%
% Outputs (these could be replaced by user-specified matrices if desired
%                 targetSa.meanReq = target mean log Sa; 
%                 targetSa.covReq  = target coveriance matrix for log Sa;
%                 targetSa.stdevs  = target standard deviations for log Sa;



%% Compute target mean spectrum
% compute the median and standard deviations of RotD50 response spectrum values 
[sa, sigma] = gmpe_bssa_2014(rup.M_bar, knownPer, rup.Rjb, rup.Fault_Type, rup.region, rup.z1, rup.Vs30);

% modify spectral targets if RotD100 values were specified for
% two-component selection, see the following document for more details:
%  Shahi, S. K., and Baker, J. W. (2014). "NGA-West2 models for ground-
%  motion directionality." Earthquake Spectra, 30(3), 1285-1300.
if selectionParams.RotD == 100 && selectionParams.arb == 2 
   [ rotD100Ratio, rotD100Sigma ] = gmpe_sb_2014_ratios( knownPer ); 
   sa = sa.*rotD100Ratio; % from equation (1) of the above paper
   sigma = sqrt ( sigma.^2 + rotD100Sigma .^2); 
end

% back-calculate an epsilon to match the target Sa(T_cond), if Sa(T_cond)
% is specified
if ~isempty(selectionParams.SaTcond)   
    medianSaTcond = exp(interp1(log(knownPer), log(sa), log(selectionParams.Tcond))); % log-log interp to get median Sa
    sigmaSaTcond = exp(interp1(log(knownPer), log(sigma), log(selectionParams.Tcond))); % log-log interp to get median Sa
    eps_bar = (log(selectionParams.SaTcond) - log(medianSaTcond))/sigmaSaTcond;
    
    display(['Back calculated epsilon = ' num2str(eps_bar,3)]); % output result for user verification
    
else % use user-specified epsilon value
    eps_bar = rup.eps_bar;
end

% (Log) Response Spectrum Mean: TgtMean
if selectionParams.cond == 1   
    % compute correlations and the conditional mean spectrum
    rho = zeros(1,length(sa));  
    for i = 1:length(sa)
        rho(i) = gmpe_bj_2008_corr(knownPer(i), selectionParams.TgtPer(selectionParams.indTcond));
    end
    
    TgtMean = log(sa) + sigma.*eps_bar.*rho;

elseif selectionParams.cond == 0
    TgtMean = log(sa);
end


%% Compute covariances and correlations at all periods 
TgtCovs = zeros(length(sa));
for i=1:length(sa)
    for j=1:length(sa)
        % Periods
        Ti = knownPer(i);
        Tj = knownPer(j);

        % Means and variances
        varT = sigma(selectionParams.indTcond)^2;
        sigma22 = varT;
        var1 = sigma(i)^2;
        var2 = sigma(j)^2;
        
        % Covariances 
        if selectionParams.cond == 1 
            sigmaCorr = gmpe_bj_2008_corr(Ti,Tj)*sqrt(var1*var2);
            sigma11 = [var1 sigmaCorr;sigmaCorr var2];
            sigma12 = [gmpe_bj_2008_corr(Ti, selectionParams.Tcond)*sqrt(var1*varT);gmpe_bj_2008_corr(selectionParams.Tcond, Tj)*sqrt(var2*varT)];
            sigmaCond = sigma11 - sigma12*inv(sigma22)*(sigma12)';
            TgtCovs(i,j) = sigmaCond(1,2);
        elseif selectionParams.cond == 0
            TgtCovs(i,j) = gmpe_bj_2008_corr(Ti, Tj)*sqrt(var1*var2);
        end
    end
end

% over-write coveriance matrix with zeros if no variance is desired in the ground motion selection
if selectionParams.useVar == 0
    TgtCovs = zeros(size(TgtCovs));
end

% find covariance values of zero and set them to a small number so that
% random number generation can be performed
TgtCovs( abs(TgtCovs) < 1e-10) = 1e-10;

% Store target mean and covariance matrix at target periods
targetSa.meanReq = TgtMean(indPer); 
targetSa.covReq  = TgtCovs(indPer,indPer);
targetSa.stdevs  = sqrt(diag(targetSa.covReq))';

% target mean and covariance at all periods
targetSa.meanAllT = TgtMean;  
targetSa.covAllT  = TgtCovs;


