!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief a module to allow the storage of the parser status
!> \author Teodoro Laino [tlaino] - University of Zurich
!> \date 08.2008
! **************************************************************************************************
MODULE cp_parser_status_types
   USE cp_parser_buffer_types,          ONLY: buffer_type,&
                                              create_buffer_type,&
                                              release_buffer_type
   USE kinds,                           ONLY: max_line_length
#include "../base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   TYPE status_type
      LOGICAL                                        :: in_use = .FALSE.
      INTEGER                                        :: old_input_line_number = HUGE(0)
      INTEGER                                        :: old_icol = HUGE(0)
      INTEGER                                        :: old_icol1 = HUGE(0)
      INTEGER                                        :: old_icol2 = HUGE(0)
      CHARACTER(LEN=max_line_length)                 :: old_input_line = ""
      ! Store status of the buffer
      TYPE(buffer_type), POINTER                     :: buffer => NULL()
   END TYPE status_type

   PUBLIC :: status_type, create_status_type, release_status_type
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'cp_parser_status_types'

CONTAINS

! ****************************************************************************
!> \brief creates the parser status type
!> \param status ...
!> \date  08.2008
!> \author Teodoro Laino [tlaino] - University of Zurich
! **************************************************************************************************
   SUBROUTINE create_status_type(status)
      TYPE(status_type), POINTER                         :: status

      CPASSERT(.NOT. ASSOCIATED(status))
      ALLOCATE (status)
      CALL create_buffer_type(status%buffer)
   END SUBROUTINE create_status_type

! ****************************************************************************
!> \brief releases the parser status type
!> \param status ...
!> \date  08.2008
!> \author Teodoro Laino [tlaino] - University of Zurich
! **************************************************************************************************
   SUBROUTINE release_status_type(status)
      TYPE(status_type), POINTER                         :: status

      CPASSERT(ASSOCIATED(status))
      CALL release_buffer_type(status%buffer)
      DEALLOCATE (status)
   END SUBROUTINE release_status_type

END MODULE cp_parser_status_types
