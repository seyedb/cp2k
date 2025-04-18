!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief function that build the field section of the input
!> \par History
!>      02.2017 moved out of input_cp2k_dft [JHU]
!> \author fawzi
! **************************************************************************************************
MODULE input_cp2k_field
   USE bibliography,                    ONLY: Souza2002,&
                                              Stengel2009,&
                                              Umari2002
   USE input_constants,                 ONLY: constant_env,&
                                              custom_env,&
                                              gaussian,&
                                              gaussian_env,&
                                              ramp_env
   USE input_keyword_types,             ONLY: keyword_create,&
                                              keyword_release,&
                                              keyword_type
   USE input_section_types,             ONLY: section_add_keyword,&
                                              section_add_subsection,&
                                              section_create,&
                                              section_release,&
                                              section_type
   USE input_val_types,                 ONLY: char_t,&
                                              real_t
   USE kinds,                           ONLY: dp
   USE string_utilities,                ONLY: s2a
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'input_cp2k_field'

   PUBLIC :: create_per_efield_section, create_efield_section

CONTAINS

! **************************************************************************************************
!> \brief creates the section for static periodic fields
!> \param section ...
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE create_per_efield_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="PERIODIC_EFIELD", &
                          description="parameters for finite periodic electric field computed using"// &
                          " the Berry phase approach. IMPORTANT: Can only be used in combination"// &
                          " with OT. Can not be used in combination with RTP or EMD,"// &
                          " e.g. RESTART_RTP has to be .FALSE. when restarting the job.", &
                          citations=(/Souza2002, Umari2002/), &
                          n_keywords=6, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, name="INTENSITY", &
                          description="Intensity of the electric field in a.u, "// &
                          "not allowed together with INTENSITY_LIST", &
                          usage="INTENSITY  0.001", &
                          default_r_val=0._dp)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="POLARISATION", &
                          description="Polarisation vector of electric field", &
                          usage="POLARISATION  0.0 0.0 1.0", &
                          repeats=.FALSE., n_var=3, &
                          type_of_var=real_t, default_r_vals=(/0.0_dp, 0.0_dp, 1.0_dp/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="DISPLACEMENT_FIELD", &
                          description="Use the displacement field formulation.", &
                          usage="DISPLACEMENT_FIELD T", &
                          citations=(/Stengel2009/), &
                          default_l_val=.FALSE., &
                          lone_keyword_l_val=.TRUE.)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="D_FILTER", &
                          description="Filter for displacement field (x,y,z-direction)", &
                          usage="D_FILTER  1.0 0.0 0.0", &
                          repeats=.FALSE., n_var=3, &
                          type_of_var=real_t, default_r_vals=(/1.0_dp, 1.0_dp, 1.0_dp/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="INTENSITY_LIST", &
                          description="Intensities of the electric field in a.u. "// &
                          "They are applied sequentially, one per frame. "// &
                          "If the number of frames exceeds the number of values, "// &
                          "the list is cyclically repeated. Attention: not implemented for eeq.", &
                          usage="INTENSITY_LIST {real} {real} .. {real}", &
                          n_var=-1, type_of_var=real_t, default_r_vals=(/0.0_dp/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="INTENSITIES_FILE_NAME", &
                          description="File containting a list of intensities, "// &
                          "one per line, in a.u. "// &
                          "They are applied sequentially, one per frame. "// &
                          "If the number of frames exceeds the number of values, "// &
                          "the list is cyclically repeated. Attention: not implemented for eeq.", &
                          usage="INTENSITIES_FILE_NAME filename", &
                          default_lc_val="")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="START_FRAME", &
                          description="First frame the field is applied. "// &
                          "(0: first frame) "// &
                          "Attention: ignored for eeq", &
                          usage="START_FRAME 0", &
                          default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="END_FRAME", &
                          description="Last frame the field is applied. "// &
                          "If an end frame is specified, the number of active frames "// &
                          "must be a multiple of the number of "// &
                          "the given intensity values. (-1: no end) "// &
                          "Attention: ignored for eeq", &
                          usage="END_FRAME -1", &
                          default_i_val=-1)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_per_efield_section
! **************************************************************************************************
!> \brief creates the section for time dependent nonperiodic fields
!> \param section ...
!> \author Florian Schiffmann
! **************************************************************************************************
   SUBROUTINE create_efield_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword
      TYPE(section_type), POINTER                        :: subsection

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="EFIELD", &
                          description="Parameters for finite, time  dependent electric fields. "// &
                          "For time dependent  propagation in periodic systems, set "// &
                          "DFT%REAL_TIME_PROPAGATION%VELOCITY_GAUGE to true. "// &
                          "For static fields use EXTERNAL_POTENTIAL.", &
                          n_keywords=6, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword, subsection)

      CALL keyword_create(keyword, __LOCATION__, name="INTENSITY", &
                          description="Intensity of the electric field. For real-time propagation (RTP) units are "// &
                          "in W*cm-2 which corresponds "// &
                          "to a maximal amplitude in a.u. of sqrt(I/(3.50944*10^16)). "// &
                          "For a constant local field in isolated system calclulations, units are in a.u..", &
                          usage="INTENSITY  0.001", &
                          default_r_val=0._dp)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="POLARISATION", &
                          description="Polarisation vector of electric field", &
                          usage="POLARISATION  0.0 0.0 1.0", &
                          repeats=.FALSE., n_var=3, &
                          type_of_var=real_t, default_r_vals=(/0.0_dp, 0.0_dp, 1.0_dp/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="WAVELENGTH", &
                          description="Wavelength of efield field for real-time propagation (RTP) calculations.", &
                          usage="Wavelength  1.E0", &
                          default_r_val=0._dp, unit_str="nm")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="PHASE", &
                          description="Phase offset of the cosine given in multiples of pi. "// &
                          "Used in real-time propagation (RTP) calculations.", &
                          usage="Phase  1.E0", &
                          default_r_val=0._dp)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="ENVELOP", &
                          description="Shape of the efield pulse used in real-time propagation (RTP) calculations.", &
                          usage="ENVELOP CONSTANT", &
                          default_i_val=constant_env, &
                          enum_c_vals=s2a("CONSTANT", "GAUSSIAN", "RAMP", "CUSTOM"), &
                          enum_desc=s2a("No envelop function is applied to the strength", &
                                        "A Gaussian function is used as envelop ", &
                                        "Linear tune in/out of the field", &
                                        "A custom field read from a file"), &
                          enum_i_vals=(/constant_env, gaussian_env, ramp_env, custom_env/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="VEC_POT_INITIAL", &
                          description="Initial value of the vector "// &
                          "potential (for velocity gauge). This input is "// &
                          "made especially for restarting RTP calculation. "// &
                          "Unit is atomic unit. "// &
                          "Note that if several field sections are defined, only the first one will be used.", &
                          usage="vec_pot_initial  1.0E-2 0.0 0.0", &
                          repeats=.FALSE., &
                          n_var=3, type_of_var=real_t, &
                          default_r_vals=(/0.0_dp, 0.0_dp, 0.0_dp/))
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL create_constant_env_section(subsection)
      CALL section_add_subsection(section, subsection)
      CALL section_release(subsection)

      CALL create_gaussian_env_section(subsection)
      CALL section_add_subsection(section, subsection)
      CALL section_release(subsection)

      CALL create_ramp_env_section(subsection)
      CALL section_add_subsection(section, subsection)
      CALL section_release(subsection)

      CALL create_custom_env_section(subsection)
      CALL section_add_subsection(section, subsection)
      CALL section_release(subsection)

   END SUBROUTINE create_efield_section

! **************************************************************************************************
!> \brief ...
!> \param section ...
! **************************************************************************************************
   SUBROUTINE create_constant_env_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="CONSTANT_ENV", &
                          description="parameters for a constant envelop", &
                          n_keywords=6, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, name="START_STEP", &
                          description="First step the field is applied ", &
                          usage="START_STEP 0", &
                          default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="END_STEP", &
                          description="Last step the field is applied", &
                          usage="END_STEP 2", &
                          default_i_val=-1)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_constant_env_section

! **************************************************************************************************
!> \brief ...
!> \param section ...
! **************************************************************************************************
   SUBROUTINE create_gaussian_env_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="GAUSSIAN_ENV", &
                          description="parameters for a gaussian envelop", &
                          n_keywords=6, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, name="T0", &
                          description="Center of the gaussian envelop (maximum of the gaussian)", &
                          usage="T0 2.0E0", &
                          default_r_val=0.0E0_dp, &
                          unit_str="fs")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="SIGMA", &
                          description="Width of the gaussian ", &
                          usage="SIGMA 2.0E0", &
                          default_r_val=-1.0E0_dp, &
                          unit_str="fs")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_gaussian_env_section

! **************************************************************************************************
!> \brief ...
!> \param section ...
! **************************************************************************************************
   SUBROUTINE create_ramp_env_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="RAMP_ENV", &
                          description="Parameters for an trapeziodal envelop ", &
                          n_keywords=6, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, name="START_STEP_IN", &
                          description="Step when the electric field starts to be applied ", &
                          usage="START_STEP_IN 0", &
                          default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="END_STEP_IN", &
                          description="Step when the field reaches the full strength", &
                          usage="END_STEP_IN 2", &
                          default_i_val=-1)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="START_STEP_OUT", &
                          description="Step when the field starts to vanish ", &
                          usage="START_STEP_OUT 0", &
                          default_i_val=0)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="END_STEP_OUT", &
                          description="Step when the field disappears", &
                          usage="END_STEP_OUT 2", &
                          default_i_val=-1)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_ramp_env_section

! **************************************************************************************************
!> \brief ...
!> \param section ...
! **************************************************************************************************
   SUBROUTINE create_custom_env_section(section)
      TYPE(section_type), POINTER                        :: section

      TYPE(keyword_type), POINTER                        :: keyword

      CPASSERT(.NOT. ASSOCIATED(section))
      CALL section_create(section, __LOCATION__, name="CUSTOM_ENV", &
                          description="Parameters for a custom efield", &
                          n_keywords=2, n_subsections=1, repeats=.TRUE.)

      NULLIFY (keyword)

      CALL keyword_create(keyword, __LOCATION__, name="EFIELD_FILE_NAME", &
                          description="Specify file that contains the electric field [V/m].", &
                          usage="EFIELD_FILE_NAME filename", &
                          n_var=1, type_of_var=char_t, default_c_val="")
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

      CALL keyword_create(keyword, __LOCATION__, name="TIMESTEP", &
                          description="The time step between the entries in the list with the electric field.", &
                          usage="TIMESTEP 1", &
                          unit_str="fs", &
                          default_r_val=1.0_dp)
      CALL section_add_keyword(section, keyword)
      CALL keyword_release(keyword)

   END SUBROUTINE create_custom_env_section

END MODULE input_cp2k_field
